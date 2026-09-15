import Foundation
import Combine
import Network

/// WiFi 传书服务 - 在本地局域网启动 HTTP 服务器，允许用户通过浏览器上传书籍
final class WiFiTransferService: NSObject, ObservableObject {
    static let shared = WiFiTransferService()

    @Published var isRunning = false
    @Published var serverURL: String?
    @Published var uploadedCount: Int = 0
    @Published var totalUploadCount: Int = 0
    @Published var uploadLog: [String] = []

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.bookreader.wifi-transfer", attributes: .concurrent)
    private let receiveChunkSize = 64 * 1024
    private let maximumHeaderSize = 32 * 1024
    private let maximumUploadBodySize = 202 * 1024 * 1024
    private let maximumSingleFileSize = 200 * 1024 * 1024
    private var sessionToken = UUID().uuidString

    private override init() {
        super.init()
    }

    /// 获取本机 IP 地址
    var localIPAddress: String? {
        var fallbackAddress: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let socketAddress = interface.ifa_addr else { continue }
            let addrFamily = socketAddress.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "lo0" { continue }

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                let address = String(cString: hostname)
                if name == "en0" {
                    return address
                }
                fallbackAddress = fallbackAddress ?? address
            }
        }
        return fallbackAddress
    }

    /// 启动服务器
    func start() -> Bool {
        guard listener == nil else { return true }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        do {
            let newListener = try NWListener(using: parameters, on: .any)
            sessionToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            uploadedCount = 0
            totalUploadCount = 0
            uploadLog = ["正在启动传书服务..."]
            listener = newListener

            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let port = newListener?.port?.rawValue
                    let ipAddress = self.localIPAddress
                    DispatchQueue.main.async {
                        guard self.listener === newListener else { return }
                        self.isRunning = true
                        if let port, let ipAddress {
                            self.serverURL = "http://\(ipAddress):\(port)/?token=\(self.sessionToken)"
                            self.uploadLog = ["服务器已启动: \(self.serverURL ?? "")"]
                        } else {
                            self.serverURL = nil
                            self.uploadLog = ["服务器已启动，但未找到可访问的 WiFi 地址"]
                        }
                    }
                case .failed(let error):
                    DispatchQueue.main.async {
                        guard self.listener === newListener else { return }
                        self.listener = nil
                        self.isRunning = false
                        self.serverURL = nil
                        self.uploadLog.append("服务器错误: \(error.localizedDescription)")
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            newListener.start(queue: queue)
            return true
        } catch {
            listener = nil
            uploadLog.append("启动失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 处理新连接
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection: connection, buffer: Data())
    }

    private func receiveRequest(connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: receiveChunkSize,
            completion: { [weak self] data, _, isComplete, error in
                guard let self else { return }

                if error != nil {
                    connection.cancel()
                    return
                }

                var updatedBuffer = buffer
                if let data {
                    updatedBuffer.append(data)
                }

                guard let headerRange = updatedBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if updatedBuffer.count > self.maximumHeaderSize {
                        self.sendResponse(connection: connection, statusCode: 431, body: "Request Header Too Large")
                    } else if isComplete {
                        self.sendResponse(connection: connection, statusCode: 400, body: "Incomplete Request")
                    } else {
                        self.receiveRequest(connection: connection, buffer: updatedBuffer)
                    }
                    return
                }

                guard headerRange.lowerBound <= self.maximumHeaderSize,
                      let headerString = String(
                        data: updatedBuffer[..<headerRange.lowerBound],
                        encoding: .utf8
                      ),
                      let requestHead = self.parseRequestHead(headerString) else {
                    self.sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
                    return
                }

                let contentLength = requestHead.headers["content-length"].flatMap(Int.init) ?? 0
                guard contentLength >= 0, contentLength <= self.maximumUploadBodySize else {
                    self.sendResponse(connection: connection, statusCode: 413, body: "Upload Too Large")
                    return
                }

                let expectedLength = headerRange.upperBound + contentLength
                guard expectedLength <= self.maximumHeaderSize + self.maximumUploadBodySize else {
                    self.sendResponse(connection: connection, statusCode: 413, body: "Upload Too Large")
                    return
                }

                if updatedBuffer.count < expectedLength {
                    if isComplete {
                        self.sendResponse(connection: connection, statusCode: 400, body: "Incomplete Request Body")
                    } else {
                        self.receiveRequest(connection: connection, buffer: updatedBuffer)
                    }
                    return
                }

                let body = Data(updatedBuffer[headerRange.upperBound..<expectedLength])
                self.handleHTTPRequest(requestHead: requestHead, body: body, connection: connection)
            }
        )
    }

    private struct HTTPRequestHead {
        let method: String
        let target: String
        let headers: [String: String]
    }

    private func parseRequestHead(_ headerString: String) -> HTTPRequestHead? {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let requestParts = firstLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count == 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        return HTTPRequestHead(
            method: String(requestParts[0]).uppercased(),
            target: String(requestParts[1]),
            headers: headers
        )
    }

    private func handleHTTPRequest(requestHead: HTTPRequestHead, body: Data, connection: NWConnection) {
        guard let components = URLComponents(string: "http://localhost\(requestHead.target)") else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        guard token == sessionToken else {
            sendResponse(connection: connection, statusCode: 401, body: "Unauthorized")
            return
        }

        switch (requestHead.method, components.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            serveUploadPage(connection: connection)
        case ("POST", "/upload"):
            let contentType = requestHead.headers["content-type"] ?? ""
            processUpload(data: body, boundary: extractBoundary(from: contentType), connection: connection)
        default:
            sendResponse(connection: connection, statusCode: 404, body: "Not Found")
        }
    }

    /// 提取 multipart boundary
    private func extractBoundary(from contentType: String) -> String {
        guard let boundaryRange = contentType.range(of: "boundary=", options: .caseInsensitive) else { return "" }
        let value = contentType[boundaryRange.upperBound...].split(separator: ";", maxSplits: 1).first ?? ""
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    /// 处理上传的文件
    private func processUpload(data: Data, boundary: String, connection: NWConnection) {
        guard !boundary.isEmpty, boundary.utf8.count <= 200 else {
            sendResponse(connection: connection, statusCode: 400, body: "Invalid multipart")
            return
        }

        let parts = multipartParts(in: data, boundary: boundary)
        var uploadedFiles: [String] = []
        var failedFiles: [String] = []
        var uploadedURLs: [URL] = []
        let uploadDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderWiFiUploads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        for part in parts {
            guard let parsedPart = parseMultipartFile(part) else { continue }
            let filename = parsedPart.filename

            // 验证文件类型
            let ext = (filename as NSString).pathExtension.lowercased()
            guard ["txt", "epub", "pdf"].contains(ext) else {
                failedFiles.append("\(filename): 不支持的格式")
                continue
            }

            guard parsedPart.data.count <= maximumSingleFileSize else {
                failedFiles.append("\(filename): 文件超过 200MB")
                continue
            }

            do {
                try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
                let destinationURL = uploadDirectory.appendingPathComponent(filename, isDirectory: false)
                try parsedPart.data.write(to: destinationURL, options: [.atomic, .withoutOverwriting])
                uploadedFiles.append(filename)
                uploadedURLs.append(destinationURL)
            } catch {
                failedFiles.append("\(filename): \(error.localizedDescription)")
            }
        }

        if uploadedURLs.isEmpty {
            try? FileManager.default.removeItem(at: uploadDirectory)
        }

        DispatchQueue.main.async {
            self.uploadedCount += uploadedFiles.count
            self.totalUploadCount += uploadedFiles.count + failedFiles.count
            for file in uploadedFiles {
                self.uploadLog.append("✅ \(file) 上传成功")
            }
            for error in failedFiles {
                self.uploadLog.append("❌ \(error)")
            }

            if !uploadedURLs.isEmpty {
                NotificationCenter.default.post(
                    name: .wifiTransferDidReceiveFiles,
                    object: self,
                    userInfo: [WiFiTransferNotificationKey.fileURLs: uploadedURLs]
                )
            }
        }

        sendJSONResponse(
            connection: connection,
            statusCode: 200,
            object: [
                "success": uploadedFiles.count,
                "failed": failedFiles.count,
                "files": uploadedFiles,
                "errors": failedFiles
            ]
        )
    }

    private func multipartParts(in data: Data, boundary: String) -> [Data] {
        let marker = Data("--\(boundary)".utf8)
        guard let firstBoundary = data.range(of: marker) else { return [] }

        var parts: [Data] = []
        var partStart = firstBoundary.upperBound
        while partStart < data.endIndex,
              let nextBoundary = data.range(of: marker, in: partStart..<data.endIndex) {
            var part = Data(data[partStart..<nextBoundary.lowerBound])
            if part.starts(with: Data("\r\n".utf8)) {
                part.removeFirst(2)
            }
            if part.suffix(2) == Data("\r\n".utf8) {
                part.removeLast(2)
            }
            if !part.isEmpty, !part.starts(with: Data("--".utf8)) {
                parts.append(part)
            }
            partStart = nextBoundary.upperBound
        }
        return parts
    }

    private func parseMultipartFile(_ part: Data) -> (filename: String, data: Data)? {
        guard let headerRange = part.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: part[..<headerRange.lowerBound], encoding: .utf8),
              let filenameMarker = header.range(of: "filename=\"", options: .caseInsensitive) else {
            return nil
        }

        let filenameTail = header[filenameMarker.upperBound...]
        guard let closingQuote = filenameTail.firstIndex(of: "\"") else { return nil }
        let rawFilename = String(filenameTail[..<closingQuote])
        guard let filename = sanitizedFilename(rawFilename) else { return nil }

        return (filename, Data(part[headerRange.upperBound...]))
    }

    private func sanitizedFilename(_ rawFilename: String) -> String? {
        let normalized = rawFilename.replacingOccurrences(of: "\\", with: "/")
        let filename = (normalized as NSString).lastPathComponent
        guard filename == normalized,
              filename != ".",
              filename != "..",
              !filename.isEmpty,
              filename.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return filename
    }

    /// 返回上传页面
    private func serveUploadPage(connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>WiFi 传书 - BookReader</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    min-height: 100vh;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    padding: 20px;
                }
                .container {
                    background: white;
                    border-radius: 20px;
                    box-shadow: 0 20px 60px rgba(0,0,0,0.15);
                    padding: 40px;
                    max-width: 500px;
                    width: 100%;
                }
                h1 {
                    text-align: center;
                    color: #333;
                    margin-bottom: 8px;
                    font-size: 28px;
                }
                .subtitle {
                    text-align: center;
                    color: #888;
                    margin-bottom: 30px;
                    font-size: 14px;
                }
                .upload-area {
                    border: 3px dashed #d0d0d0;
                    border-radius: 16px;
                    padding: 40px 20px;
                    text-align: center;
                    cursor: pointer;
                    transition: all 0.3s;
                    margin-bottom: 24px;
                    position: relative;
                }
                .upload-area:hover, .upload-area.dragover {
                    border-color: #667eea;
                    background: #f8f9ff;
                }
                .upload-area.dragover {
                    transform: scale(1.02);
                }
                .upload-icon {
                    font-size: 48px;
                    margin-bottom: 12px;
                }
                .upload-text {
                    color: #666;
                    font-size: 16px;
                    line-height: 1.6;
                }
                .upload-text strong {
                    color: #667eea;
                }
                .file-list {
                    margin-bottom: 24px;
                }
                .file-item {
                    display: flex;
                    align-items: center;
                    padding: 12px 16px;
                    background: #f8f9fa;
                    border-radius: 10px;
                    margin-bottom: 8px;
                    font-size: 14px;
                }
                .file-item .icon {
                    margin-right: 12px;
                    font-size: 20px;
                }
                .file-item .name {
                    flex: 1;
                    color: #333;
                    overflow: hidden;
                    text-overflow: ellipsis;
                    white-space: nowrap;
                }
                .file-item .size {
                    color: #999;
                    margin-left: 8px;
                    font-size: 12px;
                }
                .file-item .remove {
                    color: #ff4757;
                    cursor: pointer;
                    margin-left: 12px;
                    font-size: 18px;
                }
                .btn-upload {
                    width: 100%;
                    padding: 16px;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    color: white;
                    border: none;
                    border-radius: 12px;
                    font-size: 18px;
                    font-weight: 600;
                    cursor: pointer;
                    transition: all 0.3s;
                }
                .btn-upload:hover {
                    transform: translateY(-2px);
                    box-shadow: 0 8px 25px rgba(102, 126, 234, 0.4);
                }
                .btn-upload:disabled {
                    opacity: 0.5;
                    cursor: not-allowed;
                    transform: none;
                    box-shadow: none;
                }
                .progress-bar {
                    width: 100%;
                    height: 8px;
                    background: #eee;
                    border-radius: 4px;
                    overflow: hidden;
                    margin-top: 16px;
                    display: none;
                }
                .progress-bar.active { display: block; }
                .progress-bar .fill {
                    height: 100%;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    border-radius: 4px;
                    transition: width 0.3s;
                    width: 0%;
                }
                .result {
                    margin-top: 20px;
                    padding: 16px;
                    border-radius: 12px;
                    display: none;
                }
                .result.success {
                    background: #f0fdf4;
                    border: 1px solid #86efac;
                    color: #166534;
                }
                .result.error {
                    background: #fef2f2;
                    border: 1px solid #fca5a5;
                    color: #991b1b;
                }
                .hint {
                    text-align: center;
                    color: #aaa;
                    font-size: 12px;
                    margin-top: 20px;
                }
                input[type="file"] { display: none; }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>📚 WiFi 传书</h1>
                <p class="subtitle">支持 TXT、EPUB、PDF 格式，可批量上传</p>

                <div class="upload-area" id="dropZone">
                    <div class="upload-icon">📤</div>
                    <p class="upload-text">
                        拖拽文件到此处<br>
                        或 <strong>点击选择文件</strong>
                    </p>
                </div>

                <div class="file-list" id="fileList"></div>

                <button class="btn-upload" id="uploadBtn" disabled>开始上传</button>

                <div class="progress-bar" id="progressBar">
                    <div class="fill" id="progressFill"></div>
                </div>

                <div class="result" id="result"></div>

                <p class="hint">上传完成后，App 会自动导入书架</p>
            </div>

            <input type="file" id="fileInput" multiple accept=".txt,.epub,.pdf">
            <script>
                const dropZone = document.getElementById('dropZone');
                const fileInput = document.getElementById('fileInput');
                const fileList = document.getElementById('fileList');
                const uploadBtn = document.getElementById('uploadBtn');
                const progressBar = document.getElementById('progressBar');
                const progressFill = document.getElementById('progressFill');
                const result = document.getElementById('result');

                let selectedFiles = [];

                dropZone.addEventListener('click', () => fileInput.click());
                dropZone.addEventListener('dragover', (e) => {
                    e.preventDefault();
                    dropZone.classList.add('dragover');
                });
                dropZone.addEventListener('dragleave', () => {
                    dropZone.classList.remove('dragover');
                });
                dropZone.addEventListener('drop', (e) => {
                    e.preventDefault();
                    dropZone.classList.remove('dragover');
                    handleFiles(e.dataTransfer.files);
                });
                fileInput.addEventListener('change', () => {
                    handleFiles(fileInput.files);
                });

                function handleFiles(files) {
                    const validExts = ['txt', 'epub', 'pdf'];
                    for (let f of files) {
                        const ext = f.name.split('.').pop().toLowerCase();
                        if (!validExts.includes(ext)) {
                            alert(f.name + ' 格式不支持，仅支持 TXT、EPUB、PDF');
                            continue;
                        }
                        if (!selectedFiles.find(sf => sf.name === f.name)) {
                            selectedFiles.push(f);
                        }
                    }
                    renderFileList();
                }

                function renderFileList() {
                    fileList.innerHTML = '';
                    selectedFiles.forEach((f, i) => {
                        const div = document.createElement('div');
                        div.className = 'file-item';
                        const ext = f.name.split('.').pop().toLowerCase();
                        const icon = ext === 'pdf' ? '📕' : ext === 'epub' ? '📗' : '📄';
                        const size = f.size < 1024*1024
                            ? (f.size/1024).toFixed(1) + ' KB'
                            : (f.size/1024/1024).toFixed(1) + ' MB';
                        const iconSpan = document.createElement('span');
                        iconSpan.className = 'icon';
                        iconSpan.textContent = icon;
                        const nameSpan = document.createElement('span');
                        nameSpan.className = 'name';
                        nameSpan.textContent = f.name;
                        const sizeSpan = document.createElement('span');
                        sizeSpan.className = 'size';
                        sizeSpan.textContent = size;
                        const removeSpan = document.createElement('span');
                        removeSpan.className = 'remove';
                        removeSpan.textContent = '×';
                        removeSpan.addEventListener('click', () => removeFile(i));
                        div.append(iconSpan, nameSpan, sizeSpan, removeSpan);
                        fileList.appendChild(div);
                    });
                    uploadBtn.disabled = selectedFiles.length === 0;
                }

                function removeFile(index) {
                    selectedFiles.splice(index, 1);
                    renderFileList();
                }

                uploadBtn.addEventListener('click', async () => {
                    if (selectedFiles.length === 0) return;

                    uploadBtn.disabled = true;
                    uploadBtn.textContent = '上传中...';
                    progressBar.classList.add('active');
                    progressFill.style.width = '0%';
                    result.style.display = 'none';

                    const formData = new FormData();
                    selectedFiles.forEach(f => formData.append('files', f));

                    try {
                        const xhr = new XMLHttpRequest();
                        xhr.open('POST', '/upload' + window.location.search);

                        xhr.upload.onprogress = (e) => {
                            if (e.lengthComputable) {
                                const pct = Math.round(e.loaded / e.total * 100);
                                progressFill.style.width = pct + '%';
                            }
                        };

                        xhr.onload = () => {
                            progressBar.classList.remove('active');
                            uploadBtn.disabled = false;
                            uploadBtn.textContent = '开始上传';

                            if (xhr.status === 200) {
                                const data = JSON.parse(xhr.responseText);
                                result.className = 'result success';
                                result.style.display = 'block';
                                result.innerHTML = '✅ 成功上传 ' + data.success + ' 个文件'
                                    + (data.failed > 0 ? '<br>❌ ' + data.failed + ' 个文件失败' : '');
                                selectedFiles = [];
                                renderFileList();
                            } else {
                                result.className = 'result error';
                                result.style.display = 'block';
                                result.textContent = '上传失败，请重试';
                            }
                        };

                        xhr.onerror = () => {
                            progressBar.classList.remove('active');
                            uploadBtn.disabled = false;
                            uploadBtn.textContent = '开始上传';
                            result.className = 'result error';
                            result.style.display = 'block';
                            result.textContent = '网络错误，请检查连接';
                        };

                        xhr.send(formData);
                    } catch (e) {
                        progressBar.classList.remove('active');
                        uploadBtn.disabled = false;
                        uploadBtn.textContent = '开始上传';
                        result.className = 'result error';
                        result.style.display = 'block';
                        result.textContent = '上传出错: ' + e.message;
                    }
                });
            </script>
        </body>
        </html>
        """

        sendResponse(connection: connection, statusCode: 200, contentType: "text/html; charset=utf-8", body: html)
    }

    private func sendJSONResponse(connection: NWConnection, statusCode: Int, object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            sendResponse(connection: connection, statusCode: 500, body: "Internal Server Error")
            return
        }
        sendResponse(
            connection: connection,
            statusCode: statusCode,
            contentType: "application/json; charset=utf-8",
            bodyData: data
        )
    }

    /// 发送 HTTP 响应
    private func sendResponse(connection: NWConnection, statusCode: Int, contentType: String = "text/plain; charset=utf-8", body: String) {
        sendResponse(
            connection: connection,
            statusCode: statusCode,
            contentType: contentType,
            bodyData: Data(body.utf8)
        )
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, contentType: String, bodyData: Data) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
        case 431: statusText = "Request Header Fields Too Large"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let responseHead = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "\r\n"

        var response = Data(responseHead.utf8)
        response.append(bodyData)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// 停止服务器
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        serverURL = nil
        uploadedCount = 0
        totalUploadCount = 0
        uploadLog = []
    }
}

enum WiFiTransferNotificationKey {
    static let fileURLs = "fileURLs"
}

extension Notification.Name {
    static let wifiTransferDidReceiveFiles = Notification.Name("wifiTransferDidReceiveFiles")
}
