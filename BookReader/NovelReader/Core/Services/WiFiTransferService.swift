import Foundation
import Combine
import Network

/// 统一管理传书会话令牌与已接入连接，供监听和接收队列安全访问。
final class WiFiTransferSessionGate {
    private struct ActiveConnection {
        let connection: NWConnection
        var lastActivity: TimeInterval
        var isProcessing = false
    }

    private let lock = NSLock()
    private let maximumConnections: Int
    private var token = UUID().uuidString
    private var isActive = false
    private var connections: [ObjectIdentifier: ActiveConnection] = [:]

    init(maximumConnections: Int = 8) {
        self.maximumConnections = max(1, maximumConnections)
    }

    func activate() -> String {
        lock.lock()
        defer { lock.unlock() }
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        isActive = true
        return token
    }

    func isAuthorized(_ candidate: String?, for connectionID: ObjectIdentifier? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive && candidate == token
            && (connectionID.map { connections[$0] != nil } ?? true)
    }

    func register(
        _ connection: NWConnection,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isActive, connections.count < maximumConnections else { return false }
        connections[ObjectIdentifier(connection)] = ActiveConnection(
            connection: connection,
            lastActivity: time
        )
        return true
    }

    func markActivity(
        for connectionID: ObjectIdentifier,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        if isActive {
            connections[connectionID]?.lastActivity = time
        }
        lock.unlock()
    }

    func beginProcessing(_ connectionID: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isActive, connections[connectionID] != nil else { return false }
        connections[connectionID]?.isProcessing = true
        return true
    }

    func isRegistered(_ connectionID: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive && connections[connectionID] != nil
    }

    func expireInactive(before cutoff: TimeInterval) -> [NWConnection] {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return [] }
        let expiredIDs = connections.compactMap { entry in
            !entry.value.isProcessing && entry.value.lastActivity <= cutoff ? entry.key : nil
        }
        return expiredIDs.compactMap { connections.removeValue(forKey: $0)?.connection }
    }

    func remove(_ connectionID: ObjectIdentifier) {
        lock.lock()
        connections.removeValue(forKey: connectionID)
        lock.unlock()
    }

    func deactivate() -> [NWConnection] {
        lock.lock()
        defer { lock.unlock() }
        isActive = false
        token = UUID().uuidString
        let activeConnections = connections.values.map(\.connection)
        connections.removeAll()
        return activeConnections
    }
}

/// 仅识别独立行上的 multipart 分隔符，避免书籍正文中的相似字节截断文件。
enum WiFiMultipartBoundary {
    static func partRanges(in data: Data, boundary: String) -> [Range<Data.Index>] {
        let marker = Data("--\(boundary)".utf8)
        let nextMarker = Data("\r\n--\(boundary)".utf8)
        var openingSearchStart = data.startIndex
        var firstPartStart: Data.Index?

        while let opening = data.range(of: marker, in: openingSearchStart..<data.endIndex) {
            let isLineStart = opening.lowerBound == data.startIndex
                || (opening.lowerBound >= data.startIndex + 2
                    && data[opening.lowerBound - 2] == 13
                    && data[opening.lowerBound - 1] == 10)
            let afterMarker = opening.upperBound
            if isLineStart,
               afterMarker + 2 <= data.endIndex,
               data[afterMarker] == 13,
               data[afterMarker + 1] == 10 {
                firstPartStart = afterMarker + 2
                break
            }
            openingSearchStart = opening.lowerBound + 1
        }

        guard var partStart = firstPartStart else { return [] }
        var searchStart = partStart
        var ranges: [Range<Data.Index>] = []

        while let next = data.range(of: nextMarker, in: searchStart..<data.endIndex) {
            let afterMarker = next.upperBound
            if afterMarker + 2 <= data.endIndex,
               data[afterMarker] == 13,
               data[afterMarker + 1] == 10 {
                ranges.append(partStart..<next.lowerBound)
                partStart = afterMarker + 2
                searchStart = partStart
                continue
            }
            if afterMarker + 2 <= data.endIndex,
               data[afterMarker] == 45,
               data[afterMarker + 1] == 45,
               (afterMarker + 2 == data.endIndex
                   || (afterMarker + 4 <= data.endIndex
                       && data[afterMarker + 2] == 13
                       && data[afterMarker + 3] == 10)) {
                ranges.append(partStart..<next.lowerBound)
                return ranges
            }
            searchStart = next.lowerBound + 1
        }
        return []
    }
}

/// 服务首次创建时清理上次异常退出遗留的请求体，不触碰其他临时文件。
enum WiFiTemporaryBodyStore {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BookReaderWiFiRequestBodies", isDirectory: true)

    static func cleanupOrphanedFiles(in directory: URL = WiFiTemporaryBodyStore.directory) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return
        }
        for url in contents where UUID(uuidString: url.lastPathComponent) != nil {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }
}

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
    private let maximumMultipartHeaderSize = 16 * 1024
    private let maximumUploadBodySize = 202 * 1024 * 1024
    private let maximumSingleFileSize = 200 * 1024 * 1024
    private let connectionIdleTimeout: TimeInterval = 30
    private let connectionSweepInterval: TimeInterval = 5
    private let sessionGate = WiFiTransferSessionGate()
    private var connectionSweepTimer: DispatchSourceTimer?

    private final class RequestBuffer {
        var data = Data()
    }

    /// 将上传请求体直接写入临时文件，避免在堆内存中累积最多 202MB 的 Data。
    private final class TemporaryRequestBody {
        let url: URL
        private var handle: FileHandle?
        private(set) var count = 0

        init() throws {
            let directory = WiFiTemporaryBodyStore.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: url)
        }

        func append(_ data: Data, expectedLength: Int) throws -> Bool {
            guard count + data.count <= expectedLength else { return false }
            guard let handle else { throw CocoaError(.fileNoSuchFile) }
            try handle.write(contentsOf: data)
            count += data.count
            return true
        }

        func finish() throws {
            try handle?.synchronize()
            try handle?.close()
            handle = nil
        }

        func cleanup() {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: url)
        }

        deinit {
            cleanup()
        }
    }

    private override init() {
        super.init()
        WiFiTemporaryBodyStore.cleanupOrphanedFiles()
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
            let sessionToken = sessionGate.activate()
            uploadedCount = 0
            totalUploadCount = 0
            uploadLog = ["正在启动传书服务..."]
            listener = newListener

            let sweepTimer = DispatchSource.makeTimerSource(queue: queue)
            sweepTimer.schedule(
                deadline: .now() + connectionSweepInterval,
                repeating: connectionSweepInterval
            )
            sweepTimer.setEventHandler { [weak self] in
                guard let self else { return }
                let cutoff = ProcessInfo.processInfo.systemUptime - self.connectionIdleTimeout
                self.sessionGate.expireInactive(before: cutoff).forEach { $0.cancel() }
            }
            connectionSweepTimer = sweepTimer
            sweepTimer.resume()

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
                            self.serverURL = "http://\(ipAddress):\(port)/?token=\(sessionToken)"
                            self.uploadLog = ["服务器已启动: \(self.serverURL ?? "")"]
                        } else {
                            self.serverURL = nil
                            self.uploadLog = ["服务器已启动，但未找到可访问的 WiFi 地址"]
                        }
                    }
                case .failed(let error):
                    DispatchQueue.main.async {
                        guard self.listener === newListener else { return }
                        self.stop()
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
        guard sessionGate.register(connection) else {
            connection.cancel()
            return
        }
        let connectionID = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.sessionGate.remove(connectionID)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(connection: connection, requestBuffer: RequestBuffer())
    }

    private func receiveRequest(connection: NWConnection, requestBuffer: RequestBuffer) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: receiveChunkSize,
            completion: { [weak self] data, _, isComplete, error in
                guard let self else { return }
                let connectionID = ObjectIdentifier(connection)
                guard self.sessionGate.isRegistered(connectionID) else {
                    connection.cancel()
                    return
                }

                if error != nil {
                    connection.cancel()
                    return
                }

                if let data {
                    self.sessionGate.markActivity(for: connectionID)
                    requestBuffer.data.append(data)
                }

                guard let headerRange = requestBuffer.data.range(of: Data("\r\n\r\n".utf8)) else {
                    if requestBuffer.data.count > self.maximumHeaderSize {
                        self.sendResponse(connection: connection, statusCode: 431, body: "Request Header Too Large")
                    } else if isComplete {
                        self.sendResponse(connection: connection, statusCode: 400, body: "Incomplete Request")
                    } else {
                        self.receiveRequest(connection: connection, requestBuffer: requestBuffer)
                    }
                    return
                }

                guard headerRange.lowerBound <= self.maximumHeaderSize,
                      let headerString = String(
                        data: requestBuffer.data[..<headerRange.lowerBound],
                        encoding: .utf8
                      ),
                      let requestHead = self.parseRequestHead(headerString) else {
                    self.sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
                    return
                }

                guard let requestComponents = URLComponents(
                    string: "http://localhost\(requestHead.target)"
                ) else {
                    self.sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
                    return
                }
                let token = requestComponents.queryItems?.first(where: { $0.name == "token" })?.value
                guard self.sessionGate.isAuthorized(token, for: connectionID) else {
                    self.sendResponse(connection: connection, statusCode: 401, body: "Unauthorized")
                    return
                }

                guard requestHead.headers["transfer-encoding"] == nil else {
                    self.sendResponse(connection: connection, statusCode: 400, body: "Transfer Encoding Not Supported")
                    return
                }

                let isUpload = requestHead.method == "POST" && requestComponents.path == "/upload"
                let isUploadPage = requestHead.method == "GET"
                    && (requestComponents.path == "/" || requestComponents.path == "/index.html")
                guard isUpload || isUploadPage else {
                    self.sendResponse(connection: connection, statusCode: 404, body: "Not Found")
                    return
                }
                if isUpload {
                    let contentType = requestHead.headers["content-type"] ?? ""
                    let boundary = self.extractBoundary(from: contentType)
                    guard contentType.lowercased().hasPrefix("multipart/form-data;"),
                          !boundary.isEmpty,
                          boundary.utf8.count <= 200 else {
                        self.sendResponse(connection: connection, statusCode: 400, body: "Invalid multipart")
                        return
                    }
                }
                if isUpload, requestHead.headers["content-length"] == nil {
                    self.sendResponse(connection: connection, statusCode: 411, body: "Content Length Required")
                    return
                }

                let contentLength: Int
                if let rawContentLength = requestHead.headers["content-length"] {
                    guard let parsedContentLength = Int(rawContentLength) else {
                        self.sendResponse(connection: connection, statusCode: 400, body: "Invalid Content Length")
                        return
                    }
                    contentLength = parsedContentLength
                } else {
                    contentLength = 0
                }
                let maximumBodySize = isUpload ? self.maximumUploadBodySize : 0
                guard contentLength >= 0, contentLength <= maximumBodySize else {
                    self.sendResponse(connection: connection, statusCode: 413, body: "Upload Too Large")
                    return
                }

                let initialBody = Data(requestBuffer.data[headerRange.upperBound...])
                guard contentLength > 0 else {
                    guard initialBody.isEmpty else {
                        self.sendResponse(connection: connection, statusCode: 400, body: "Unexpected Request Body")
                        return
                    }
                    self.handleHTTPRequest(
                        requestHead: requestHead,
                        bodyFileURL: nil,
                        connection: connection
                    )
                    return
                }

                do {
                    let requestBody = try TemporaryRequestBody()
                    guard try requestBody.append(initialBody, expectedLength: contentLength) else {
                        self.sendResponse(connection: connection, statusCode: 400, body: "Request Body Too Large")
                        return
                    }

                    if requestBody.count == contentLength {
                        try requestBody.finish()
                        self.handleHTTPRequest(
                            requestHead: requestHead,
                            bodyFileURL: requestBody.url,
                            connection: connection
                        )
                        requestBody.cleanup()
                    } else if isComplete {
                        requestBody.cleanup()
                        self.sendResponse(connection: connection, statusCode: 400, body: "Incomplete Request Body")
                    } else {
                        self.receiveRequestBody(
                            connection: connection,
                            requestHead: requestHead,
                            requestBody: requestBody,
                            expectedLength: contentLength
                        )
                    }
                } catch {
                    self.sendResponse(connection: connection, statusCode: 500, body: "Unable To Store Upload")
                }
            }
        )
    }

    private func receiveRequestBody(
        connection: NWConnection,
        requestHead: HTTPRequestHead,
        requestBody: TemporaryRequestBody,
        expectedLength: Int
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: receiveChunkSize
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let connectionID = ObjectIdentifier(connection)
            guard self.sessionGate.isRegistered(connectionID) else {
                requestBody.cleanup()
                connection.cancel()
                return
            }
            guard error == nil else {
                requestBody.cleanup()
                connection.cancel()
                return
            }

            do {
                if let data, !data.isEmpty {
                    self.sessionGate.markActivity(for: connectionID)
                }
                if let data,
                   try requestBody.append(data, expectedLength: expectedLength) == false {
                    requestBody.cleanup()
                    self.sendResponse(connection: connection, statusCode: 400, body: "Request Body Too Large")
                    return
                }

                if requestBody.count == expectedLength {
                    try requestBody.finish()
                    self.handleHTTPRequest(
                        requestHead: requestHead,
                        bodyFileURL: requestBody.url,
                        connection: connection
                    )
                    requestBody.cleanup()
                } else if isComplete {
                    requestBody.cleanup()
                    self.sendResponse(connection: connection, statusCode: 400, body: "Incomplete Request Body")
                } else {
                    self.receiveRequestBody(
                        connection: connection,
                        requestHead: requestHead,
                        requestBody: requestBody,
                        expectedLength: expectedLength
                    )
                }
            } catch {
                requestBody.cleanup()
                self.sendResponse(connection: connection, statusCode: 500, body: "Unable To Store Upload")
            }
        }
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

    private func handleHTTPRequest(
        requestHead: HTTPRequestHead,
        bodyFileURL: URL?,
        connection: NWConnection
    ) {
        guard let components = URLComponents(string: "http://localhost\(requestHead.target)") else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        guard let token, sessionGate.isAuthorized(token, for: ObjectIdentifier(connection)) else {
            sendResponse(connection: connection, statusCode: 401, body: "Unauthorized")
            return
        }

        switch (requestHead.method, components.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            serveUploadPage(connection: connection)
        case ("POST", "/upload"):
            let contentType = requestHead.headers["content-type"] ?? ""
            guard let bodyFileURL else {
                sendResponse(connection: connection, statusCode: 400, body: "Missing Request Body")
                return
            }
            guard sessionGate.beginProcessing(ObjectIdentifier(connection)) else {
                connection.cancel()
                return
            }
            processUpload(
                bodyFileURL: bodyFileURL,
                boundary: extractBoundary(from: contentType),
                sessionToken: token,
                connection: connection
            )
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
    private func processUpload(
        bodyFileURL: URL,
        boundary: String,
        sessionToken: String,
        connection: NWConnection
    ) {
        guard !boundary.isEmpty, boundary.utf8.count <= 200 else {
            sendResponse(connection: connection, statusCode: 400, body: "Invalid multipart")
            return
        }

        guard let data = try? Data(contentsOf: bodyFileURL, options: .alwaysMapped) else {
            sendResponse(connection: connection, statusCode: 400, body: "Unreadable multipart")
            return
        }

        let partRanges = WiFiMultipartBoundary.partRanges(in: data, boundary: boundary)
        guard !partRanges.isEmpty else {
            sendResponse(connection: connection, statusCode: 400, body: "Invalid multipart")
            return
        }

        var uploadedFiles: [String] = []
        var failedFiles: [String] = []
        var uploadedURLs: [URL] = []
        var receivedFilenames = Set<String>()
        let uploadDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderWiFiUploads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        for partRange in partRanges {
            guard let parsedPart = parseMultipartFile(in: data, partRange: partRange) else { continue }
            let filename = parsedPart.filename
            guard receivedFilenames.insert(filename.lowercased()).inserted else {
                failedFiles.append("\(filename): 同一批次存在重名文件")
                continue
            }

            // 验证文件类型
            let ext = (filename as NSString).pathExtension.lowercased()
            guard ["txt", "epub", "pdf"].contains(ext) else {
                failedFiles.append("\(filename): 不支持的格式")
                continue
            }

            guard parsedPart.dataRange.count <= maximumSingleFileSize else {
                failedFiles.append("\(filename): 文件超过 200MB")
                continue
            }

            let destinationURL = uploadDirectory.appendingPathComponent(filename, isDirectory: false)
            do {
                try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
                try copyFileRange(
                    parsedPart.dataRange,
                    from: bodyFileURL,
                    to: destinationURL
                )
                uploadedFiles.append(filename)
                uploadedURLs.append(destinationURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                failedFiles.append("\(filename): \(error.localizedDescription)")
            }
        }

        if uploadedURLs.isEmpty {
            try? FileManager.default.removeItem(at: uploadDirectory)
        }

        DispatchQueue.main.async {
            guard self.sessionGate.isAuthorized(sessionToken, for: ObjectIdentifier(connection)) else {
                try? FileManager.default.removeItem(at: uploadDirectory)
                self.sendResponse(connection: connection, statusCode: 401, body: "Unauthorized")
                return
            }
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
            self.sendJSONResponse(connection: connection, statusCode: 200, object: [
                "success": uploadedFiles.count,
                "failed": failedFiles.count,
                "files": uploadedFiles,
                "errors": failedFiles
            ])
        }
    }

    private func copyFileRange(
        _ range: Range<Data.Index>,
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteFileExists)
        }

        let source = try FileHandle(forReadingFrom: sourceURL)
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? source.close()
            try? destination.close()
        }

        try source.seek(toOffset: UInt64(range.lowerBound))
        var remaining = range.count
        while remaining > 0 {
            let chunkSize = min(receiveChunkSize, remaining)
            guard let chunk = try source.read(upToCount: chunkSize), !chunk.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            try destination.write(contentsOf: chunk)
            remaining -= chunk.count
        }
        try destination.synchronize()
    }

    private func parseMultipartFile(
        in data: Data,
        partRange: Range<Data.Index>
    ) -> (filename: String, dataRange: Range<Data.Index>)? {
        let headerSearchUpperBound = min(
            partRange.upperBound,
            data.index(partRange.lowerBound, offsetBy: maximumMultipartHeaderSize, limitedBy: partRange.upperBound)
                ?? partRange.upperBound
        )
        guard let headerRange = data.range(
                of: Data("\r\n\r\n".utf8),
                in: partRange.lowerBound..<headerSearchUpperBound
              ),
              let header = String(data: data[partRange.lowerBound..<headerRange.lowerBound], encoding: .utf8),
              let filenameMarker = header.range(of: "filename=\"", options: .caseInsensitive) else {
            return nil
        }

        let filenameTail = header[filenameMarker.upperBound...]
        guard let closingQuote = filenameTail.firstIndex(of: "\"") else { return nil }
        let rawFilename = String(filenameTail[..<closingQuote])
        guard let filename = sanitizedFilename(rawFilename) else { return nil }

        return (filename, headerRange.upperBound..<partRange.upperBound)
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
        case 411: statusText = "Length Required"
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
            + "Cache-Control: no-store\r\n"
            + "Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'\r\n"
            + "Referrer-Policy: no-referrer\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "X-Frame-Options: DENY\r\n"
            + "\r\n"

        var response = Data(responseHead.utf8)
        response.append(bodyData)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// 停止服务器
    func stop() {
        let activeConnections = sessionGate.deactivate()
        connectionSweepTimer?.cancel()
        connectionSweepTimer = nil
        listener?.cancel()
        listener = nil
        activeConnections.forEach { $0.cancel() }
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
