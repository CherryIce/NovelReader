import Foundation
import Network

/// WiFi 传书服务 - 在本地局域网启动 HTTP 服务器，允许用户通过浏览器上传书籍
class WiFiTransferService: NSObject, ObservableObject {
    static let shared = WiFiTransferService()

    @Published var isRunning = false
    @Published var serverURL: String?
    @Published var uploadedCount: Int = 0
    @Published var totalUploadCount: Int = 0
    @Published var currentUploadingFile: String = ""
    @Published var uploadProgress: Double = 0
    @Published var uploadLog: [String] = []

    private var server: HTTPServer?
    private var listener: NWListener?
    private var port: UInt16 = 8080
    private let queue = DispatchQueue(label: "com.bookreader.wifi-transfer", attributes: .concurrent)

    private override init() {
        super.init()
    }

    /// 获取本机 IP 地址
    var localIPAddress: String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                // 跳过回环地址
                let name = String(cString: interface.ifa_name)
                if name == "lo0" { continue }

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                address = String(cString: hostname)
                break
            }
        }
        return address
    }

    /// 启动服务器
    func start() -> Bool {
        guard !isRunning else { return true }

        // 尝试找到可用端口
        for tryPort: UInt16 in 8080..<8100 {
            if tryStartServer(on: tryPort) {
                port = tryPort
                isRunning = true
                uploadedCount = 0
                totalUploadCount = 0
                uploadLog = []
                if let ip = localIPAddress {
                    serverURL = "http://\(ip):\(port)"
                }
                uploadLog.append("服务器已启动: \(serverURL ?? "未知地址")")
                return true
            }
        }

        uploadLog.append("启动失败：无法找到可用端口")
        return false
    }

    /// 尝试在指定端口启动
    private func tryStartServer(on port: UInt16) -> Bool {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    break
                case .failed(let error):
                    DispatchQueue.main.async {
                        self?.isRunning = false
                        self?.serverURL = nil
                        self?.uploadLog.append("服务器错误: \(error.localizedDescription)")
                    }
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.start(queue: queue)
            return true
        } catch {
            return false
        }
    }

    /// 处理新连接
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)

        // 读取请求
        readRequest(connection: connection)
    }

    /// 读取 HTTP 请求
    private func readRequest(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }

            // 解析 HTTP 请求
            if let requestString = String(data: data, encoding: .utf8) {
                self.handleHTTPRequest(requestString, connection: connection)
            } else {
                // 二进制数据，可能是上传的文件体
                self.handleHTTPRequest("", connection: connection)
            }
        }
    }

    /// 处理 HTTP 请求
    private func handleHTTPRequest(_ requestString: String, connection: NWConnection) {
        let lines = requestString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        let firstLine = lines[0]
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // 解析 headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let colonIndex = line.firstIndex(of: ":")
            if let colonIndex = colonIndex {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // 路由
        if method == "GET" && path == "/" || path == "/index.html" {
            serveUploadPage(connection: connection)
        } else if method == "POST" && path == "/upload" {
            // 读取请求体
            readUploadBody(connection: connection, headers: headers, firstData: nil)
        } else if method == "GET" && path == "/status" {
            serveStatus(connection: connection)
        } else {
            sendResponse(connection: connection, statusCode: 404, body: "Not Found")
        }
    }

    /// 读取上传的文件体
    private func readUploadBody(connection: NWConnection, headers: [String: String], firstData: Data?) {
        var allData = firstData ?? Data()

        // 获取 Content-Length
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0

        if contentLength == 0 {
            sendResponse(connection: connection, statusCode: 400, body: "No Content-Length")
            return
        }

        // 获取 boundary
        let contentType = headers["content-type"] ?? ""
        let boundary = extractBoundary(from: contentType)

        connection.receive(minimumIncompleteLength: contentLength, maximumLength: contentLength + 1024) { [weak self] data, _, _, error in
            guard let self = self else { return }

            if let data = data {
                allData.append(data)
            }

            if allData.count >= contentLength {
                self.processUpload(data: allData, boundary: boundary, connection: connection)
            } else {
                // 继续读取
                self.readUploadBody(connection: connection, headers: headers, firstData: allData)
            }
        }
    }

    /// 提取 multipart boundary
    private func extractBoundary(from contentType: String) -> String {
        guard let boundaryRange = contentType.range(of: "boundary=") else { return "" }
        let boundary = String(contentType[boundaryRange.upperBound...])
        // 去除可能的引号
        return boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// 处理上传的文件
    private func processUpload(data: Data, boundary: String, connection: NWConnection) {
        guard !boundary.isEmpty else {
            sendResponse(connection: connection, statusCode: 400, body: "Invalid multipart")
            return
        }

        let boundaryData = "--\(boundary)".data(using: .utf8)!

        // 分割 multipart 数据
        let parts = data.split(separator: boundaryData, omittingEmptySubsequences: false)

        var uploadedFiles: [String] = []
        var failedFiles: [String] = []

        for part in parts {
            guard !part.isEmpty else { continue }
            let partString = String(data: part, encoding: .utf8) ?? ""

            // 提取文件名
            guard let filenameRange = partString.range(of: "filename=\"", options: .caseInsensitive) else { continue }
            let afterFilename = partString[filenameRange.upperBound...]
            guard let endQuote = afterFilename.firstIndex(of: "\"") else { continue }
            let filename = String(afterFilename[..<endQuote])

            // 提取文件内容（在空行之后）
            guard let headerEndRange = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let fileData = part[headerEndRange.upperBound...]

            // 去除末尾的 \r\n
            var cleanData = fileData
            if cleanData.count >= 2 {
                cleanData.removeLast(2)
            }

            // 验证文件类型
            let ext = (filename as NSString).pathExtension.lowercased()
            guard ["txt", "epub", "pdf"].contains(ext) else {
                failedFiles.append("\(filename): 不支持的格式")
                continue
            }

            // 保存文件
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let booksDir = documentsDir.appendingPathComponent("Books")
            try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)

            let destinationURL = booksDir.appendingPathComponent(filename)

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try cleanData.write(to: destinationURL)
                uploadedFiles.append(filename)
            } catch {
                failedFiles.append("\(filename): \(error.localizedDescription)")
            }
        }

        // 返回结果
        var result = "{"
        result += "\"success\": \(uploadedFiles.count),"
        result += "\"failed\": \(failedFiles.count),"
        result += "\"files\": ["
        result += uploadedFiles.map { "\"\($0)\"" }.joined(separator: ",")
        result += "],"
        result += "\"errors\": ["
        result += failedFiles.map { "\"\($0)\"" }.joined(separator: ",")
        result += "]}"

        DispatchQueue.main.async {
            self.uploadedCount += uploadedFiles.count
            self.totalUploadCount += uploadedFiles.count + failedFiles.count
            for file in uploadedFiles {
                self.uploadLog.append("✅ \(file) 上传成功")
            }
            for error in failedFiles {
                self.uploadLog.append("❌ \(error)")
            }
        }

        sendResponse(connection: connection,
                     statusCode: 200,
                     contentType: "application/json",
                     body: result)
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

                <p class="hint">上传完成后，请在 App 中刷新书架查看</p>
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
                        div.innerHTML = '<span class="icon">' + icon + '</span>'
                            + '<span class="name">' + f.name + '</span>'
                            + '<span class="size">' + size + '</span>'
                            + '<span class="remove" onclick="removeFile(' + i + ')">×</span>';
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
                        xhr.open('POST', '/upload');

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

    /// 返回状态 JSON
    private func serveStatus(connection: NWConnection) {
        let status = "{"
        status += "\"isRunning\": \(isRunning),"
        status += "\"uploadedCount\": \(uploadedCount),"
        status += "\"serverURL\": \"\(serverURL ?? "")\""
        status += "}"
        sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: status)
    }

    /// 发送 HTTP 响应
    private func sendResponse(connection: NWConnection, statusCode: Int, contentType: String = "text/plain; charset=utf-8", body: String) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "\r\n"
            + body

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
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

// MARK: - NWConnection 扩展

private extension NWConnection {
    func receive(minimumIncompleteLength: Int, maximumLength: Int, handler: @escaping (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void) {
        self.receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength) { data, context, isComplete, error in
            handler(data, context, isComplete, error)
        }
    }
}
