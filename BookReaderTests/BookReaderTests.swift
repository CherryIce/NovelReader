import Combine
import CoreText
import CoreData
import Foundation
import Network
import PDFKit
import Testing
import UIKit
@testable import BookReader

struct BookReaderTests {
    @Test func libraryDefaultsToShowingAllBooks() {
        let viewModel = LibraryViewModel()

        #expect(viewModel.currentFilter == .all)
    }

    @Test func wifiTransferSessionGateRevokesStoppedSession() throws {
        let gate = WiFiTransferSessionGate()
        let firstToken = gate.activate()
        let port = try #require(NWEndpoint.Port(rawValue: 12345))
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: .tcp
        )
        defer { connection.cancel() }

        #expect(gate.isAuthorized(firstToken))
        #expect(gate.register(connection))
        let stoppedConnections = gate.deactivate()
        #expect(stoppedConnections.count == 1)
        #expect(stoppedConnections.first === connection)
        #expect(!gate.isAuthorized(firstToken))
        #expect(!gate.register(connection))

        let secondToken = gate.activate()
        #expect(secondToken != firstToken)
        #expect(gate.isAuthorized(secondToken))
        #expect(!gate.isAuthorized(firstToken))
        _ = gate.deactivate()
    }

    @Test func wifiTransferSessionGateCapsAndExpiresIdleConnections() throws {
        let gate = WiFiTransferSessionGate(maximumConnections: 2)
        let token = gate.activate()
        let port = try #require(NWEndpoint.Port(rawValue: 12345))
        let connections = (0..<3).map { _ in
            NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: port, using: .tcp)
        }
        defer { connections.forEach { $0.cancel() } }
        let firstID = ObjectIdentifier(connections[0])
        let secondID = ObjectIdentifier(connections[1])
        let thirdID = ObjectIdentifier(connections[2])

        #expect(gate.register(connections[0], at: 10))
        #expect(gate.register(connections[1], at: 10))
        #expect(!gate.register(connections[2], at: 10))
        gate.markActivity(for: firstID, at: 25)
        #expect(gate.beginProcessing(secondID))
        #expect(gate.expireInactive(before: 20).isEmpty)

        let expired = gate.expireInactive(before: 30)
        #expect(expired.count == 1)
        #expect(expired.first === connections[0])
        #expect(!gate.isAuthorized(token, for: firstID))
        #expect(gate.register(connections[2], at: 31))
        #expect(gate.isAuthorized(token, for: thirdID))

        let laterExpired = gate.expireInactive(before: 100)
        #expect(laterExpired.count == 1)
        #expect(laterExpired.first === connections[2])
        let remaining = gate.deactivate()
        #expect(remaining.count == 1)
        #expect(remaining.first === connections[1])
    }

    @Test func wifiMultipartBoundaryPreservesMarkerLikeTextInsideFiles() throws {
        let boundary = "BookReaderBoundary"
        let firstPart = "Content-Disposition: form-data; name=\"files\"; filename=\"one.txt\"\r\n"
            + "Content-Type: text/plain\r\n\r\n"
            + "正文--\(boundary)仍是正文\r\n--\(boundary)X也不是分隔符"
        let secondPart = "Content-Disposition: form-data; name=\"files\"; filename=\"two.txt\"\r\n\r\n第二本"
        let body = Data(
            "--\(boundary)\r\n\(firstPart)\r\n--\(boundary)\r\n\(secondPart)\r\n--\(boundary)--\r\n".utf8
        )

        let ranges = WiFiMultipartBoundary.partRanges(in: body, boundary: boundary)
        #expect(ranges.count == 2)
        let firstRange = try #require(ranges.first)
        let lastRange = try #require(ranges.last)
        #expect(String(decoding: body[firstRange], as: UTF8.self) == firstPart)
        #expect(String(decoding: body[lastRange], as: UTF8.self) == secondPart)

        let incompleteBody = Data("--\(boundary)\r\n\(firstPart)\r\n--\(boundary)X".utf8)
        #expect(WiFiMultipartBoundary.partRanges(in: incompleteBody, boundary: boundary).isEmpty)
    }

    @Test func wifiTemporaryBodyCleanupOnlyRemovesOrphanedRequestFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderWiFiCleanupTest-\(UUID().uuidString)", isDirectory: true)
        let orphanedBody = directory.appendingPathComponent(UUID().uuidString)
        let unrelatedFile = directory.appendingPathComponent("keep.txt")
        let unrelatedDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("unfinished".utf8).write(to: orphanedBody)
        try Data("keep".utf8).write(to: unrelatedFile)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)

        WiFiTemporaryBodyStore.cleanupOrphanedFiles(in: directory)

        #expect(!FileManager.default.fileExists(atPath: orphanedBody.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedFile.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedDirectory.path))
    }

    @Test func wifiTemporaryUploadCleanupOnlyRemovesOrphanedBatchDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderWiFiUploadCleanupTest-\(UUID().uuidString)", isDirectory: true)
        let orphanedBatch = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unrelatedDirectory = directory.appendingPathComponent("keep", isDirectory: true)
        let unrelatedFile = directory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: orphanedBatch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unrelatedFile)

        WiFiTemporaryUploadStore.cleanupOrphanedDirectories(in: directory)

        #expect(!FileManager.default.fileExists(atPath: orphanedBatch.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    @Test func wifiTemporarySpaceBudgetCountsReservationsAndPendingFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderWiFiBudgetTest-\(UUID().uuidString)", isDirectory: true)
        let bodies = root.appendingPathComponent("bodies", isDirectory: true)
        let uploads = root.appendingPathComponent("uploads", isDirectory: true)
        let batch = uploads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let receivedFile = batch.appendingPathComponent("pending.txt")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let budget = WiFiTemporarySpaceBudget(maximumBytes: 100, directories: [bodies, uploads])

        func isQuotaRejected(for size: Int) -> Bool {
            do {
                let unexpected = try budget.reserve(requestBodyBytes: size)
                unexpected.release()
                return false
            } catch WiFiTemporarySpaceError.quotaExceeded {
                return true
            } catch {
                return false
            }
        }

        let first = try budget.reserve(requestBodyBytes: 40)
        #expect(isQuotaRejected(for: 11))
        first.release()

        try Data(repeating: 0x61, count: 35).write(to: receivedFile)
        let second = try budget.reserve(requestBodyBytes: 30)
        #expect(isQuotaRejected(for: 3))
        second.release()
        try FileManager.default.removeItem(at: receivedFile)

        let third = try budget.reserve(requestBodyBytes: 40)
        third.release()
    }

    @Test func wifiFileCopyStopsBetweenChunks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderWiFiCopyTest-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x61, count: 256 * 1024)
        try payload.write(to: source)

        var checks = 0
        var wasCancelled = false
        do {
            try WiFiFileRangeCopier.copy(
                0..<payload.count,
                from: source,
                to: destination,
                chunkSize: 64 * 1024,
                isActive: {
                    checks += 1
                    return checks <= 2
                }
            )
        } catch is CancellationError {
            wasCancelled = true
        }

        let writtenBytes = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int
        #expect(wasCancelled)
        #expect(writtenBytes == 64 * 1024)
    }

    @Test @MainActor func wifiTransferReceivesMultipartAndStopsItsHTTPServer() async throws {
        let service = WiFiTransferService.shared
        let recorder = WiFiReceivedFilesRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .wifiTransferDidReceiveFiles,
            object: service,
            queue: nil
        ) { notification in
            recorder.capture(notification)
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            service.stop()
            for fileURL in recorder.fileURLs {
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            }
        }

        try #require(service.start())
        for _ in 0..<200 where service.serverURL == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let advertisedURL = try #require(service.serverURL)
        var components = try #require(URLComponents(string: advertisedURL))
        components.host = "127.0.0.1"
        components.path = "/upload"
        let uploadURL = try #require(components.url)
        let boundary = "BookReaderHTTPBoundary"
        let filename = "loopback-\(UUID().uuidString).txt"
        let fileContent = "正文--\(boundary)\r\n--\(boundary)X仍是正文"
        let bodyString = "--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: text/plain\r\n\r\n\(fileContent)\r\n--\(boundary)--\r\n"
        let body = Data(bodyString.utf8)
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 10
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        let result = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        #expect(result["success"] as? Int == 1)
        let receivedURL = try #require(recorder.fileURLs.first)
        #expect(receivedURL.lastPathComponent == filename)
        #expect(try String(contentsOf: receivedURL, encoding: .utf8) == fileContent)

        let requestBodyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderWiFiRequestBodies", isDirectory: true)
        let existingBodies = Set(
            (try? FileManager.default.contentsOfDirectory(
                at: requestBodyDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
        )
        let portNumber = try #require(components.port)
        let port = try #require(NWEndpoint.Port(rawValue: UInt16(portNumber)))
        let query = try #require(components.percentEncodedQuery)
        let idleConnection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: .tcp
        )
        let idleProbe = WiFiConnectionProbe()
        idleConnection.stateUpdateHandler = { state in
            if case .ready = state {
                idleProbe.markReady()
            }
            if case .failed = state {
                idleProbe.markClosed()
            }
        }
        idleConnection.start(queue: DispatchQueue(label: "com.bookreader.tests.idle-upload"))
        defer { idleConnection.cancel() }
        for _ in 0..<100 where !idleProbe.isReady {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(idleProbe.isReady)
        idleConnection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { _, _, isComplete, error in
            if isComplete || error != nil {
                idleProbe.markClosed()
            }
        }
        let idleStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<180 where !idleProbe.isClosed {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        #expect(idleProbe.isClosed)
        #expect(ProcessInfo.processInfo.systemUptime - idleStart >= 29)

        let pendingConnection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: .tcp
        )
        let connectionProbe = WiFiConnectionProbe()
        pendingConnection.stateUpdateHandler = { state in
            if case .ready = state {
                connectionProbe.markReady()
            }
            if case .failed = state {
                connectionProbe.markClosed()
            }
        }
        pendingConnection.start(queue: DispatchQueue(label: "com.bookreader.tests.partial-upload"))
        defer { pendingConnection.cancel() }
        for _ in 0..<100 where !connectionProbe.isReady {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(connectionProbe.isReady)

        let partialBody = "--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"unfinished.txt\"\r\n\r\n部分正文"
        let partialRequest = "POST /upload?\(query) HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Content-Type: multipart/form-data; boundary=\(boundary)\r\n"
            + "Content-Length: \(partialBody.utf8.count + 10_000)\r\n\r\n"
            + partialBody
        pendingConnection.send(content: Data(partialRequest.utf8), completion: .contentProcessed { _ in })
        pendingConnection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { _, _, isComplete, error in
            if isComplete || error != nil {
                connectionProbe.markClosed()
            }
        }
        var pendingBodyURL: URL?
        for _ in 0..<100 where pendingBodyURL == nil {
            let currentBodies = (try? FileManager.default.contentsOfDirectory(
                at: requestBodyDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            pendingBodyURL = currentBodies.first(where: { !existingBodies.contains($0) })
            if pendingBodyURL == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let unfinishedBodyURL = try #require(pendingBodyURL)
        var writtenByteCount = 0
        for _ in 0..<100 where writtenByteCount == 0 {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: unfinishedBodyURL.path) {
                writtenByteCount = attributes[.size] as? Int ?? 0
            }
            if writtenByteCount == 0 {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        #expect(writtenByteCount > 0)

        service.stop()
        for _ in 0..<100 where (FileManager.default.fileExists(atPath: unfinishedBodyURL.path)
            || !connectionProbe.isClosed) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!FileManager.default.fileExists(atPath: unfinishedBodyURL.path))
        #expect(connectionProbe.isClosed)
        #expect(recorder.fileURLs == [receivedURL])
        var stoppedRequest = URLRequest(url: uploadURL)
        stoppedRequest.timeoutInterval = 2
        do {
            _ = try await URLSession.shared.data(for: stoppedRequest)
            Issue.record("Stopped WiFi transfer server still accepted an HTTP request")
        } catch {
            // The listener and its accepted connections should already be closed.
        }
    }

    @Test func txtParserUsesUTF16Offsets() throws {
        let content = "序言😀\n第一章 开始\n正文😀\n第二章 继续\n结尾"
        let fileURL = temporaryFileURL(name: "offsets.txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let parsed = try TXTParser().parse(fileURL: fileURL)

        #expect(parsed.chapters.count == 3)
        #expect(parsed.chapters[0].length == "序言😀".utf16.count)
        #expect(parsed.chapters[1].startLocation == "序言😀".utf16.count)
        #expect(parsed.chapters[2].startLocation == "序言😀正文😀".utf16.count)
    }

    @Test func txtParserFallsBackAfterASCIIOnlyPrefix() throws {
        let content = String(repeating: "A", count: 5_000) + "\n第一章\n中文正文"
        let fileURL = temporaryFileURL(name: "gb18030.txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let data = try #require(content.data(using: .gb_18030_2000))
        try data.write(to: fileURL, options: .atomic)

        let parsed = try TXTParser().parse(fileURL: fileURL)

        #expect(parsed.chapters.last?.content == "中文正文")
    }

    @Test func txtParserDoesNotSplitNumberLeadingProse() throws {
        let content = """
        序言
        第一章
        开始阅读。
        10分钟过去……
        一阵风吹来。
        第二章
        1、……
        2、……
        这一章仍在继续。
        第二十二章
        六月七号上午。
        正文继续。
        """
        let fileURL = temporaryFileURL(name: "number-leading-prose.txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let parsed = try TXTParser().parse(fileURL: fileURL)

        #expect(parsed.chapters.map(\.title) == ["前言", "第一章", "第二章", "第二十二章"])
        #expect(parsed.chapters[1].content.contains("10分钟过去……\n一阵风吹来。"))
        #expect(parsed.chapters[2].content.contains("1、……\n2、……"))
        #expect(parsed.chapters[3].content.hasPrefix("六月七号上午。"))
    }

    @Test func txtParserKeepsAdjacentRealHeadings() throws {
        let fileURL = temporaryFileURL(name: "adjacent-chapters.txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "第一章\n第二章\n正文".write(to: fileURL, atomically: true, encoding: .utf8)

        let chapters = try TXTParser().parse(fileURL: fileURL).chapters

        #expect(chapters.map(\.title) == ["第一章", "第二章"])
        #expect(chapters[0].content.isEmpty)
        #expect(chapters[1].content == "正文")
    }

    @Test func txtParserStillRecognizesPairedAndNumberedHeadings() throws {
        let bracketedURL = temporaryFileURL(name: "bracketed-chapters.txt")
        let numberedURL = temporaryFileURL(name: "numbered-chapters.txt")
        defer {
            try? FileManager.default.removeItem(at: bracketedURL)
            try? FileManager.default.removeItem(at: numberedURL)
        }
        try "【一】 起点\n正文甲\n【二】 终点\n正文乙".write(
            to: bracketedURL, atomically: true, encoding: .utf8
        )
        try "1. 起点\n\(String(repeating: "正文", count: 25))\n2. 终点\n正文乙".write(
            to: numberedURL, atomically: true, encoding: .utf8
        )

        #expect(try TXTParser().parse(fileURL: bracketedURL).chapters.map(\.title) == ["【一】 起点", "【二】 终点"])
        #expect(try TXTParser().parse(fileURL: numberedURL).chapters.map(\.title) == ["1. 起点", "2. 终点"])
    }

    @Test func pdfOutlineRangesIgnoreDuplicatesAndInvalidDestinations() {
        let ranges = PDFParser.normalizedPageRanges(
            pageIndices: [4, 2, 2, -1, 99, 1],
            pageCount: 6
        )

        #expect(ranges == [
            PDFParser.PageRange(startPage: 0, endPage: 0),
            PDFParser.PageRange(startPage: 1, endPage: 1),
            PDFParser.PageRange(startPage: 2, endPage: 3),
            PDFParser.PageRange(startPage: 4, endPage: 5)
        ])
        #expect(PDFParser.normalizedPageRanges(pageIndices: [], pageCount: 6).isEmpty)
        #expect(PDFParser.normalizedPageRanges(pageIndices: [0], pageCount: 2) == [
            PDFParser.PageRange(startPage: 0, endPage: 1)
        ])
        #expect(PDFParser.normalizedPageRanges(pageIndices: [0], pageCount: 0).isEmpty)
    }

    @Test func pdfOutlinePreservesPrefaceBeforeFirstDestination() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let pdfData = renderer.pdfData { context in
            for text in ["Preface text", "Chapter text"] {
                context.beginPage()
                (text as NSString).draw(
                    at: CGPoint(x: 20, y: 20),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
                )
            }
        }
        let document = try #require(PDFDocument(data: pdfData))
        let chapterPage = try #require(document.page(at: 1))
        let outlineRoot = PDFOutline()
        let chapterOutline = PDFOutline()
        chapterOutline.label = "第一章"
        chapterOutline.destination = PDFDestination(page: chapterPage, at: .zero)
        outlineRoot.insertChild(chapterOutline, at: 0)
        document.outlineRoot = outlineRoot

        let fileURL = temporaryFileURL(name: "preface-outline.pdf")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        #expect(document.write(to: fileURL))

        let parsed = try PDFParser().parse(fileURL: fileURL)
        let chapter = try #require(parsed.chapters.dropFirst().first)
        #expect(parsed.chapters.map(\.title) == ["前言", "第一章"])
        #expect(parsed.chapters.map(\.content) == ["Preface text", "Chapter text"])
        #expect(chapter.startLocation == "Preface text".utf16.count)
    }

    @Test func epubParserReadsAStandardDeflatedArchive() throws {
        let base64Archive = """
        UEsDBBQAAAAAAK2EL11vYassFAAAABQAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi9lcHViK3ppcFBLAwQUAAAACACthC9dYaJ2fpYAAADPAAAAFgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWxNjsEOwiAQRH+l2atp0SsBmph41sQvQLpVIuwSoEb/XvRQvU0y82ZGjc8Yugfm4pk07IYtjEY5pmo9Ye6aS0XDkkmyLb5IshGLrE5yQprYLRGpym9MrhgYlZnr7AOWn+zmJYQ+2XrTcDzsT2fxARo+cJqhizh529dXQg02peCdre2UYLyk0jB3t1fctCUQRom/frHumjdQSwMEFAAAAAgArYQvXceBkkQHAQAAewEAABEAAABPRUJQUy9jb250ZW50Lm9wZlWQsU7DMBRFf8XyihonLKDIcTe+AD7Asl8SC9uxnAcpGwt0qMTGxsCExMTEgAR/Q0s/gzQNqRif7tG5epfPF86Sa4itaXxBsySlBLxqtPFVQS/Oz2andC54kOpSVkB62LcFrRFDzljXdYnRoUyaWLHjND1hTSjpHsq1mrhwFe3AaMXAggOPLcuSjFHBHaDUEqXgWuVo0ILYPC/Xy/v1w+rn83Xzvtq+PX5/vHA25TtSRZDYRDHmX0/b27sB+Qs4O5id9KaEFgU3CI4YXVBVy4AQM0rqCOXhThY1OkuJA23kDG8CFFSGYI2S2C/Ehvio/5CyXcUkboPxsPf3vr7in3WAR4SNW4pfUEsDBBQAAAAIAK2EL106Hr3/lwAAAKUAAAAUAAAAT0VCUFMvY2hhcHRlcjEueGh0bWyzySjJzVGoyM3JK7ZVyigpKbDS1y8vL9crN9bLL0rXN7S0tNSvAKlRsrPJSE1MsbMpySzJSbV7uqT9+ZQVzxa0v1w0w0YfImajD1GRlJ9SCVRtaPd8zZonOxqer14AlDG0symwA6p/2t6m4OLq5uMY4qrwbO3iZ9PaFdQScwusFZ6u63k2dcvjhiYb/QKgURBD9EFW2wEAUEsBAhQDFAAAAAAArYQvXW9hqywUAAAAFAAAAAgAAAAAAAAAAAAAAIABAAAAAG1pbWV0eXBlUEsBAhQDFAAAAAgArYQvXWGidn6WAAAAzwAAABYAAAAAAAAAAAAAAIABOgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWxQSwECFAMUAAAACACthC9dx4GSRAcBAAB7AQAAEQAAAAAAAAAAAAAAgAEEAQAAT0VCUFMvY29udGVudC5vcGZQSwECFAMUAAAACACthC9dOh69/5cAAAClAAAAFAAAAAAAAAAAAAAAgAE6AgAAT0VCUFMvY2hhcHRlcjEueGh0bWxQSwUGAAAAAAQABAD7AAAAAwMAAAAA
        """
        let archiveData = try #require(
            Data(base64Encoded: base64Archive, options: .ignoreUnknownCharacters)
        )
        let fileURL = temporaryFileURL(name: "standard-deflated.epub")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try archiveData.write(to: fileURL, options: .atomic)

        let parsed = try EPUBParser().parse(fileURL: fileURL)

        #expect(parsed.title == "标准压缩测试书")
        #expect(parsed.author == "测试作者")
        #expect(parsed.chapters.map(\.title) == ["第一章"])
        #expect(parsed.chapters.first?.content.contains("标准 DEFLATE 正文 & 完整。") == true)
    }

    @Test func parserSizeErrorReportsTheFormatSpecificLimit() {
        let error = ParserError.fileTooLarge(
            actualSize: 201 * 1024 * 1024,
            maximumSize: 200 * 1024 * 1024
        )

        #expect(error.errorDescription?.contains("超过 200MB") == true)
    }

    @Test func pageCacheRequiresAnExactPaginationDescriptor() throws {
        let bookId = UUID()
        defer { PageCacheManager.shared.clearCache(for: bookId) }
        let descriptor = makeDescriptor(viewportWidth: 390)
        let chapters = [
            Chapter(index: 0, title: "第一章", content: "第一页", length: 3)
        ]
        let pages = [
            Page(
                globalIndex: 0,
                content: "第一页",
                chapterIndex: 0,
                chapterTitle: "第一章",
                isChapterStart: true,
                contentOffset: 0
            )
        ]

        PageCacheManager.shared.saveCache(pages: pages, for: bookId, descriptor: descriptor)

        let cached = try #require(
            PageCacheManager.shared.loadCache(
                for: bookId,
                expectedDescriptor: descriptor,
                chapters: chapters
            )
        )
        #expect(cached.map(\.content) == ["第一页"])
        #expect(
            PageCacheManager.shared.loadCache(
                for: bookId,
                expectedDescriptor: makeDescriptor(viewportWidth: 430),
                chapters: chapters
            ) == nil
        )
    }

    @Test func pageCacheRejectsPagesOutsideReadingOrder() {
        let bookId = UUID()
        defer { PageCacheManager.shared.clearCache(for: bookId) }
        let pages = [
            Page(
                globalIndex: 0,
                content: "efg",
                chapterIndex: 0,
                chapterTitle: "正文",
                isChapterStart: true,
                contentOffset: 4
            ),
            Page(
                globalIndex: 1,
                content: "bcd",
                chapterIndex: 0,
                chapterTitle: "正文",
                isChapterStart: false,
                contentOffset: 1
            )
        ]

        PageCacheManager.shared.saveCache(
            pages: pages,
            for: bookId,
            descriptor: makeDescriptor(viewportWidth: 390)
        )

        #expect(PageCacheManager.shared.loadCache(
            for: bookId,
            expectedDescriptor: makeDescriptor(viewportWidth: 390),
            chapters: [Chapter(index: 0, title: "正文", content: "abcdefghij")]
        ) == nil)
        #expect(!PageCacheManager.shared.hasCache(for: bookId))
    }

    @Test func pageCacheRestoresCompleteUTF16CoverageAcrossEmptyChapters() throws {
        let bookId = UUID()
        defer { PageCacheManager.shared.clearCache(for: bookId) }
        let descriptor = makeDescriptor(viewportWidth: 390)
        let chapters = [
            Chapter(index: 0, title: "开篇", content: "甲😀乙"),
            Chapter(index: 1, title: "空章", content: ""),
            Chapter(index: 2, title: "结尾", content: "终")
        ]
        let pages = [
            Page(globalIndex: 0, content: "甲😀", chapterIndex: 0, chapterTitle: "开篇", isChapterStart: true, contentOffset: 0),
            Page(globalIndex: 1, content: "乙", chapterIndex: 0, chapterTitle: "开篇", isChapterStart: false, contentOffset: 3),
            Page(globalIndex: 2, content: "终", chapterIndex: 2, chapterTitle: "结尾", isChapterStart: true, contentOffset: 0)
        ]

        PageCacheManager.shared.saveCache(pages: pages, for: bookId, descriptor: descriptor)
        let cached = try #require(PageCacheManager.shared.loadCache(
            for: bookId,
            expectedDescriptor: descriptor,
            chapters: chapters
        ))

        #expect(cached.map(\.content) == ["甲😀", "乙", "终"])
        #expect(cached.map(\.contentOffset) == [0, 3, 0])
    }

    @Test func pageCacheRejectsIncompleteOrInconsistentCoverage() {
        let descriptor = makeDescriptor(viewportWidth: 390)
        let chapters = [
            Chapter(index: 0, title: "一", content: "abcd"),
            Chapter(index: 1, title: "二", content: "ef")
        ]
        func page(
            _ globalIndex: Int,
            _ content: String,
            chapterIndex: Int,
            offset: Int,
            title: String? = nil,
            isChapterStart: Bool
        ) -> Page {
            Page(
                globalIndex: globalIndex,
                content: content,
                chapterIndex: chapterIndex,
                chapterTitle: title ?? chapters[chapterIndex].title,
                isChapterStart: isChapterStart,
                contentOffset: offset
            )
        }
        let invalidPageSets = [
            [page(0, "ab", chapterIndex: 0, offset: 0, isChapterStart: true),
             page(1, "ef", chapterIndex: 1, offset: 0, isChapterStart: true)],
            [page(0, "abcd", chapterIndex: 0, offset: 0, isChapterStart: true)],
            [page(0, "ab", chapterIndex: 0, offset: 0, isChapterStart: true),
             page(1, "d", chapterIndex: 0, offset: 3, isChapterStart: false),
             page(2, "ef", chapterIndex: 1, offset: 0, isChapterStart: true)],
            [page(0, "abc", chapterIndex: 0, offset: 0, isChapterStart: true),
             page(1, "cd", chapterIndex: 0, offset: 2, isChapterStart: false),
             page(2, "ef", chapterIndex: 1, offset: 0, isChapterStart: true)],
            [page(0, "abcd", chapterIndex: 0, offset: 0, title: "旧标题", isChapterStart: true),
             page(1, "ef", chapterIndex: 1, offset: 0, isChapterStart: true)],
            [page(0, "abcd", chapterIndex: 0, offset: 0, isChapterStart: false),
             page(1, "ef", chapterIndex: 1, offset: 0, isChapterStart: true)]
        ]

        for pages in invalidPageSets {
            let bookId = UUID()
            PageCacheManager.shared.saveCache(pages: pages, for: bookId, descriptor: descriptor)
            #expect(PageCacheManager.shared.loadCache(
                for: bookId,
                expectedDescriptor: descriptor,
                chapters: chapters
            ) == nil)
            #expect(!PageCacheManager.shared.hasCache(for: bookId))
            PageCacheManager.shared.clearCache(for: bookId)
        }
    }

    @Test func pageLocatorFindsChapterRangesAndUTF16Offsets() {
        let pages = [
            Page(globalIndex: 0, content: "甲", chapterIndex: 1, chapterTitle: "一", isChapterStart: true, contentOffset: 0),
            Page(globalIndex: 1, content: "乙", chapterIndex: 1, chapterTitle: "一", isChapterStart: false, contentOffset: 10),
            Page(globalIndex: 2, content: "丙", chapterIndex: 3, chapterTitle: "三", isChapterStart: true, contentOffset: 0)
        ]

        #expect(ReaderPageLocator.chapterRange(1, in: pages) == 0..<2)
        #expect(ReaderPageLocator.chapterRange(2, in: pages) == nil)
        #expect(ReaderPageLocator.chapterRange(3, in: pages) == 2..<3)
        #expect(ReaderPageLocator.pageIndex(containing: -1, inChapter: 1, pages: pages) == 0)
        #expect(ReaderPageLocator.pageIndex(containing: 9, inChapter: 1, pages: pages) == 0)
        #expect(ReaderPageLocator.pageIndex(containing: 10, inChapter: 1, pages: pages) == 1)
        #expect(ReaderPageLocator.pageIndex(containing: Int.max, inChapter: 1, pages: pages) == 1)
        #expect(ReaderPageLocator.nextContentOffset(after: 0, in: pages) == 10)
        #expect(ReaderPageLocator.nextContentOffset(after: 1, in: pages) == nil)
    }

    @Test func pageLocatorDoesNotConfuseOldGlobalIndexWithNewPage() {
        let stalePage = Page(
            globalIndex: 0,
            content: "丙",
            chapterIndex: 2,
            chapterTitle: "二",
            isChapterStart: false,
            contentOffset: 10
        )
        let pages = [
            Page(globalIndex: 0, content: "甲", chapterIndex: 1, chapterTitle: "一", isChapterStart: true, contentOffset: 0),
            Page(globalIndex: 1, content: "乙", chapterIndex: 2, chapterTitle: "二", isChapterStart: true, contentOffset: 0),
            Page(globalIndex: 2, content: "丙", chapterIndex: 2, chapterTitle: "二", isChapterStart: false, contentOffset: 10)
        ]

        #expect(ReaderPageLocator.pageIndex(matching: stalePage, in: pages) == 2)
        #expect(ReaderPageLocator.pageIndex(matching: pages[0], in: pages) == 0)
        #expect(ReaderPageLocator.pageIndex(matching: Page(
            globalIndex: 0,
            content: "旧排版页面",
            chapterIndex: 2,
            chapterTitle: "二",
            isChapterStart: false,
            contentOffset: 10
        ), in: pages) == nil)
        #expect(ReaderPageLocator.pageIndex(matching: Page(
            globalIndex: 0,
            content: "缺失",
            chapterIndex: 2,
            chapterTitle: "二",
            isChapterStart: false,
            contentOffset: 5
        ), in: pages) == nil)
    }

    @Test @MainActor func bookmarkJumpLoadsAnUnpaginatedChapter() async throws {
        let book = Book(
            title: "章节跳转",
            filePath: "/tmp/BookReaderTests-\(UUID().uuidString)-missing.txt",
            format: .txt
        )
        defer { PageCacheManager.shared.clearCache(for: book.id) }
        let viewModel = ReaderViewModel(
            book: book,
            bookRepository: RecordingBookRepository()
        )
        viewModel.setAvailableViewSize(CGSize(width: 120, height: 160))
        viewModel.chapters = [
            Chapter(index: 0, title: "一", content: "首页"),
            Chapter(index: 1, title: "二", content: "中间章节"),
            Chapter(index: 2, title: "三", content: String(repeating: "正文", count: 300))
        ]
        viewModel.pages = [
            Page(
                globalIndex: 0,
                content: "首页",
                chapterIndex: 0,
                chapterTitle: "一",
                isChapterStart: true,
                contentOffset: 0
            )
        ]

        let targetOffset = 250
        viewModel.jumpToBookmark(Bookmark(
            bookId: book.id,
            chapterIndex: 2,
            location: targetOffset
        ))
        for _ in 0..<300 where viewModel.isPreparingRemainingPages {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let page = try #require(viewModel.currentPage)
        #expect(page.chapterIndex == 2)
        #expect(page.contentOffset <= targetOffset)
        #expect(
            (ReaderPageLocator.nextContentOffset(
                after: viewModel.currentPageIndex,
                in: viewModel.pages
            ) ?? Int.max) > targetOffset
        )
        #expect(!viewModel.isPreparingRemainingPages)
        for _ in 0..<200 where !PageCacheManager.shared.hasCache(for: book.id) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(PageCacheManager.shared.hasCache(for: book.id))
    }

    @Test func cancelledPaginationStopsBeforeProducingPages() {
        let token = PaginationCancellationToken()
        token.cancel()
        let chapter = Chapter(index: 0, title: "正文", content: String(repeating: "长", count: 10_000))

        let pages = ReaderPaginationService().paginate(
            chapters: [chapter],
            descriptor: makeDescriptor(viewportWidth: 120, viewportHeight: 160),
            cancellationToken: token
        )

        #expect(pages.isEmpty)
    }

    @Test func paginationPlanPrioritizesFocusedAndAdjacentChapters() {
        #expect(
            ReaderPaginationPlan.priorityOrder(
                chapterCount: 5,
                focusedChapterIndex: 2
            ) == [2, 1, 3, 0, 4]
        )
        #expect(
            ReaderPaginationPlan.focusedAndAdjacentIndexes(
                chapterCount: 5,
                focusedChapterIndex: 2
            ) == [1, 2, 3]
        )
        #expect(
            ReaderPaginationPlan.focusedAndAdjacentIndexes(
                chapterCount: 5,
                focusedChapterIndex: 0
            ) == [0, 1]
        )
    }

    @Test func paginationPlanRestoresReadingOrderWhenMergingStages() {
        let pagesByChapter = [
            2: [Page(
                globalIndex: 0,
                content: "第三章",
                chapterIndex: 2,
                chapterTitle: "第三章",
                isChapterStart: true,
                contentOffset: 0
            )],
            1: [Page(
                globalIndex: 0,
                content: "第二章",
                chapterIndex: 1,
                chapterTitle: "第二章",
                isChapterStart: true,
                contentOffset: 0
            )]
        ]

        let merged = ReaderPaginationPlan.mergedPages(
            chapterIndexes: [2, 1],
            pagesByChapter: pagesByChapter
        )

        #expect(merged.map(\.chapterIndex) == [1, 2])
        #expect(merged.map(\.globalIndex) == [0, 1])
        #expect(merged.map(\.content).joined() == "第二章第三章")
    }

    @Test func singleChapterPaginationKeepsItsLogicalChapterIndex() {
        let content = String(repeating: "正文", count: 200)
        let chapter = Chapter(
            index: 7,
            title: "第八章",
            content: content,
            length: content.utf16.count
        )

        let pages = ReaderPaginationService().paginateChapter(
            chapter,
            chapterIndex: 7,
            descriptor: makeDescriptor(viewportWidth: 160, viewportHeight: 240)
        )

        #expect(!pages.isEmpty)
        #expect(pages.allSatisfy { $0.chapterIndex == 7 })
        #expect(pages.map(\.globalIndex) == Array(pages.indices))
        #expect(pages.map(\.content).joined() == content)
    }

    @Test func paginationDoesNotTruncateBooksOverFiveHundredPages() {
        let content = String(repeating: "长", count: 700)
            + String(repeating: "\n", count: 700)
            + "结尾"
        let chapter = Chapter(
            index: 0,
            title: "长篇",
            content: content,
            length: content.utf16.count
        )
        let pages = ReaderPaginationService().paginate(
            chapters: [chapter],
            descriptor: makeDescriptor(viewportWidth: 80, viewportHeight: 80)
        )

        #expect(pages.count > 500)
        #expect(pages.map(\.content).joined() == content)
        #expect(pages.last?.contentOffset != nil)
    }

    @Test func everyPaginatedPageFitsTheCoreTextRenderingFrame() {
        let descriptor = makeDescriptor(viewportWidth: 360, viewportHeight: 779)
        let paragraph = "要求释放被捕学生。英帝国主义的巡捕镇压群众运动。"
        let content = Array(repeating: paragraph, count: 200).joined(separator: "\n")
        let chapter = Chapter(
            index: 0,
            title: "第 11-20 页",
            content: content,
            length: content.utf16.count
        )

        let pages = ReaderPaginationService().paginate(
            chapters: [chapter],
            descriptor: descriptor
        )
        let textContainerSize = ReaderTextLayout.textContainerSize(for: descriptor)

        #expect(!pages.isEmpty)
        for page in pages {
            let attributedText = ReaderTextLayout.attributedString(
                page.content,
                descriptor: descriptor
            )
            let framesetter = CTFramesetterCreateWithAttributedString(
                attributedText as CFAttributedString
            )
            let frame = ReaderTextLayout.frame(
                framesetter: framesetter,
                range: CFRange(location: 0, length: attributedText.length),
                containerSize: textContainerSize
            )
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            let lines = CTFrameGetLines(frame) as? [CTLine] ?? []

            #expect(visibleRange.location == 0)
            #expect(visibleRange.length == attributedText.length)
            #expect(lastLineBottom(in: frame, lines: lines) >= 0)
        }
        #expect(pages.map(\.content).joined() == content)
    }

    @Test func readerSelectionUsesStableUTF16OffsetsAcrossPages() throws {
        let pages = [
            Page(
                globalIndex: 0,
                content: "甲😀乙丙",
                chapterIndex: 0,
                chapterTitle: "正文",
                isChapterStart: true,
                contentOffset: 0
            ),
            Page(
                globalIndex: 1,
                content: "丁戊己庚",
                chapterIndex: 0,
                chapterTitle: "正文",
                isChapterStart: false,
                contentOffset: 5
            )
        ]
        let selection = ReaderTextSelection(
            chapterIndex: 0,
            anchorOffset: 8,
            focusOffset: 1
        )

        let selectedParts = try pages.compactMap { page -> String? in
            guard let range = selection.localRange(in: page) else { return nil }
            return (page.content as NSString).substring(with: range)
        }

        #expect(selection.range == NSRange(location: 1, length: 7))
        #expect(selectedParts.joined() == "😀乙丙丁戊己")
    }

    @Test func readerSelectionStartsOnAWholeUnicodeCharacter() {
        let range = ReaderTextRangeMath.initialRange(in: "甲😀乙", utf16Offset: 1)
        let lowerBoundary = ReaderTextRangeMath.composedCharacterBoundary(
            in: "甲😀乙",
            utf16Offset: 2,
            preferUpperBoundary: false
        )
        let upperBoundary = ReaderTextRangeMath.composedCharacterBoundary(
            in: "甲😀乙",
            utf16Offset: 2,
            preferUpperBoundary: true
        )

        #expect(range == NSRange(location: 1, length: 2))
        #expect(("甲😀乙" as NSString).substring(with: range) == "😀")
        #expect(lowerBoundary == 1)
        #expect(upperBoundary == 3)
    }

    @Test func annotationRenderingTrimsIndentationAndResolvesOverlaps() throws {
        let visibleRange = try #require(
            ReaderTextRangeMath.trimmingLineWhitespace(
                in: "　　正 文　 ",
                range: NSRange(location: 0, length: 7)
            )
        )
        let blankRange = ReaderTextRangeMath.trimmingLineWhitespace(
            in: "　 \n",
            range: NSRange(location: 0, length: 3)
        )
        let persistedMarks = [
            ReaderTextMark(range: NSRange(location: 2, length: 5), style: .highlight),
            ReaderTextMark(range: NSRange(location: 4, length: 4), style: .note)
        ]
        let resolvedMarks = ReaderTextRangeMath.resolvedMarks(
            pageLength: 12,
            persistedMarks: persistedMarks,
            activeRange: NSRange(location: 1, length: 8)
        )
        let uncoveredRanges = ReaderTextRangeMath.uncoveredRanges(
            in: NSRange(location: 1, length: 8),
            coveredRanges: persistedMarks.map(\.range)
        )

        #expect(("　　正 文　 " as NSString).substring(with: visibleRange) == "正 文")
        #expect(blankRange == nil)
        #expect(resolvedMarks == [
            ReaderTextMark(range: NSRange(location: 1, length: 1), style: .active),
            ReaderTextMark(range: NSRange(location: 2, length: 2), style: .highlight),
            ReaderTextMark(range: NSRange(location: 4, length: 4), style: .note),
            ReaderTextMark(range: NSRange(location: 8, length: 1), style: .active)
        ])
        #expect(uncoveredRanges == [
            NSRange(location: 1, length: 1),
            NSRange(location: 8, length: 1)
        ])
    }

    @Test func readerTapTargetsAreMutuallyExclusive() {
        #expect(
            ReaderPageTapRouting.target(
                isToolbarSafeArea: true,
                isAnnotationHit: true,
                isCenterTap: true
            ) == .toolbar
        )
        #expect(
            ReaderPageTapRouting.target(
                isToolbarSafeArea: false,
                isAnnotationHit: true,
                isCenterTap: true
            ) == .annotation
        )
        #expect(
            ReaderPageTapRouting.target(
                isToolbarSafeArea: false,
                isAnnotationHit: false,
                isCenterTap: true
            ) == .toolbar
        )
        #expect(
            ReaderPageTapRouting.target(
                isToolbarSafeArea: false,
                isAnnotationHit: false,
                isCenterTap: false
            ) == .none
        )
    }

    @Test func noteAnnotationPersistsItsSelectedRangeAndComment() async throws {
        let persistence = PersistenceController(inMemory: true)
        let bookRepository = BookRepository(context: persistence.container.newBackgroundContext())
        let bookmarkRepository = BookmarkRepository(context: persistence.container.newBackgroundContext())
        let book = Book(title: "批注测试", filePath: "/tmp/annotation.txt", format: .txt)
        let note = Bookmark(
            bookId: book.id,
            chapterIndex: 2,
            location: 18,
            length: 7,
            type: .note,
            note: "这一段很重要",
            selectedText: "被选择的原文"
        )

        _ = try await publisherValue(bookRepository.addBook(book))
        _ = try await publisherValue(bookmarkRepository.addBookmark(note))
        let saved = try #require(
            try await publisherValue(bookmarkRepository.getBookmarks(forBookId: book.id)).first
        )

        #expect(saved.chapterIndex == 2)
        #expect(saved.location == 18)
        #expect(saved.length == 7)
        #expect(saved.type == .note)
        #expect(saved.note == "这一段很重要")
        #expect(saved.selectedText == "被选择的原文")
    }

    @Test func annotationDetailGroupsAndManagesUpToFiveThoughts() async throws {
        let persistence = PersistenceController(inMemory: true)
        let bookRepository = BookRepository(context: persistence.container.newBackgroundContext())
        let bookmarkRepository = BookmarkRepository(context: persistence.container.newBackgroundContext())
        let book = Book(title: "想法管理测试", filePath: "/tmp/thoughts.txt", format: .txt)
        let highlight = Bookmark(
            bookId: book.id,
            chapterIndex: 1,
            location: 12,
            length: 6,
            type: .highlight,
            selectedText: "划线原文"
        )

        _ = try await publisherValue(bookRepository.addBook(book))
        _ = try await publisherValue(bookmarkRepository.addBookmark(highlight))

        for index in 1...ReaderAnnotationGroup.maximumThoughtCount {
            let thought = Bookmark(
                bookId: book.id,
                chapterIndex: highlight.chapterIndex,
                location: highlight.location,
                length: highlight.length,
                type: .note,
                note: "想法 \(index)",
                selectedText: highlight.selectedText
            )
            _ = try await publisherValue(bookmarkRepository.addBookmark(thought))
        }

        let savedRecords = try await publisherValue(
            bookmarkRepository.getBookmarks(forBookId: book.id)
        )
        let fullGroup = try #require(ReaderAnnotationGroup.groups(from: savedRecords).first)

        #expect(fullGroup.selectedText == "划线原文")
        #expect(fullGroup.records.count == 6)
        #expect(fullGroup.thoughts.count == ReaderAnnotationGroup.maximumThoughtCount)
        #expect(!fullGroup.canAddThought)

        var editedThought = try #require(fullGroup.thoughts.first)
        editedThought.note = "修改后的想法"
        editedThought.updatedAt = Date()
        _ = try await publisherValue(bookmarkRepository.updateBookmark(editedThought))
        _ = try await publisherValue(
            bookmarkRepository.deleteBookmark(byId: try #require(fullGroup.thoughts.last).id)
        )

        let updatedRecords = try await publisherValue(
            bookmarkRepository.getBookmarks(forBookId: book.id)
        )
        let updatedGroup = try #require(ReaderAnnotationGroup.groups(from: updatedRecords).first)

        #expect(updatedGroup.thoughts.count == 4)
        #expect(updatedGroup.canAddThought)
        #expect(updatedGroup.thoughts.contains { $0.note == "修改后的想法" })
    }

    @Test func completedStatusSurvivesReadingAnEarlierPage() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = BookRepository(context: persistence.container.newBackgroundContext())
        let book = Book(
            title: "测试书籍",
            filePath: "/tmp/test-book.txt",
            format: .txt,
            readingStatus: .reading
        )

        _ = try await publisherValue(repository.addBook(book))
        _ = try await publisherValue(
            repository.updateReadingProgress(
                bookId: book.id,
                chapterIndex: 3,
                contentOffset: 120,
                isCompleted: true
            )
        )
        #expect(try await publisherValue(repository.getBook(byId: book.id))?.readingStatus == .completed)

        _ = try await publisherValue(
            repository.updateReadingProgress(
                bookId: book.id,
                chapterIndex: 1,
                contentOffset: 20,
                isCompleted: false
            )
        )
        #expect(try await publisherValue(repository.getBook(byId: book.id))?.readingStatus == .completed)
        #expect(try await publisherValue(repository.getRecentlyReadBooks(limit: 10)).isEmpty)

        let activeBook = Book(title: "在读书籍", filePath: "/tmp/active.txt", format: .txt)
        _ = try await publisherValue(repository.addBook(activeBook))
        _ = try await publisherValue(
            repository.updateReadingProgress(
                bookId: activeBook.id,
                chapterIndex: 0,
                contentOffset: 0,
                isCompleted: false
            )
        )
        let readingBooks = try await publisherValue(repository.getRecentlyReadBooks(limit: 10))
        #expect(readingBooks.map(\.id) == [activeBook.id])
    }

    @Test func loadBookUseCaseParsesAndPersistsMissingChapters() async throws {
        let persistence = PersistenceController(inMemory: true)
        let bookRepository = BookRepository(context: persistence.container.newBackgroundContext())
        let chapterRepository = ChapterRepository(context: persistence.container.newBackgroundContext())
        let book = Book(title: "旧数据", filePath: "/tmp/legacy.txt", format: .txt)
        let parsedChapters = [
            Chapter(index: 0, title: "正文", content: "补建的章节", length: 5)
        ]
        let useCase = LoadBookUseCase(
            bookRepository: bookRepository,
            chapterRepository: chapterRepository,
            parser: StubBookParser(chapters: parsedChapters)
        )

        _ = try await publisherValue(bookRepository.addBook(book))
        let loaded = try await publisherValue(
            useCase.execute(bookId: book.id, fileURL: URL(fileURLWithPath: book.filePath))
        )

        #expect(loaded.0.id == book.id)
        #expect(loaded.1.map(\.content) == ["补建的章节"])
        #expect(
            try await publisherValue(chapterRepository.getChapters(forBookId: book.id))
                .map(\.content) == ["补建的章节"]
        )
    }

    @Test func loadBookUseCaseRepairsLegacyTXTChaptersAndPreservesPositions() async throws {
        let booksDirectory = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Books", isDirectory: true)
        try FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        let fileURL = booksDirectory.appendingPathComponent("legacy-\(UUID().uuidString).txt")
        let stalePath = "/var/mobile/Containers/Data/Application/old-container/Documents/Books/\(fileURL.lastPathComponent)"
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "序言\n第一章\n开始。\n一阵风吹来\n下一段文字。\n第二章\n尾声。".write(
            to: fileURL, atomically: true, encoding: .utf8
        )

        let persistence = PersistenceController(inMemory: true)
        let bookRepository = BookRepository(context: persistence.container.newBackgroundContext())
        let chapterRepository = ChapterRepository(context: persistence.container.newBackgroundContext())
        let bookmarkRepository = BookmarkRepository(context: persistence.container.newBackgroundContext())
        let book = Book(
            title: "旧目录",
            filePath: stalePath,
            format: .txt,
            lastReadChapterIndex: 2,
            lastReadContentOffset: 2
        )
        let legacy = [
            Chapter(index: 0, title: "前言", content: "序言"),
            Chapter(index: 1, title: "第一章", content: "开始。"),
            Chapter(index: 2, title: "一阵风吹来", content: "下一段文字。"),
            Chapter(index: 3, title: "第二章", content: "尾声。")
        ]
        _ = try await publisherValue(bookRepository.addBook(book, chapters: legacy))
        let bookmark = Bookmark(bookId: book.id, chapterIndex: 2, location: 3, selectedText: "段文字")
        _ = try await publisherValue(bookmarkRepository.addBookmark(bookmark))

        let useCase = LoadBookUseCase(
            bookRepository: bookRepository,
            chapterRepository: chapterRepository,
            parser: FormatAwareBookParser()
        )
        let (updatedBook, chapters) = try await publisherValue(
            useCase.execute(bookId: book.id, fileURL: URL(fileURLWithPath: stalePath))
        )
        let newContent = chapters[1].content as NSString
        let bodyStart = newContent.range(of: "下一段文字。").location

        #expect(chapters.map(\.title) == ["前言", "第一章", "第二章"])
        #expect(updatedBook.filePath == fileURL.path)
        #expect(try await publisherValue(bookRepository.getBook(byId: book.id))?.filePath == fileURL.path)
        #expect(newContent.contains("一阵风吹来"))
        #expect(updatedBook.lastReadChapterIndex == 1)
        #expect(updatedBook.lastReadContentOffset == bodyStart + 2)
        let savedBookmark = try #require(
            try await publisherValue(bookmarkRepository.getBookmarks(forBookId: book.id)).first
        )
        let freshBookmarkRepository = BookmarkRepository(
            context: persistence.container.newBackgroundContext()
        )
        let freshBookmark = try #require(
            try await publisherValue(freshBookmarkRepository.getBookmarks(forBookId: book.id)).first
        )
        #expect(savedBookmark.id == bookmark.id)
        #expect(savedBookmark.chapterIndex == 1)
        #expect(savedBookmark.location == bodyStart + 3)
        #expect(savedBookmark.selectedText == bookmark.selectedText)
        #expect(freshBookmark.chapterIndex == 1)
        #expect(freshBookmark.location == bodyStart + 3)

        let loadedAgain = try await publisherValue(
            useCase.execute(bookId: book.id, fileURL: URL(fileURLWithPath: stalePath))
        )
        #expect(loadedAgain.1.map(\.id) == chapters.map(\.id))
        #expect(loadedAgain.0.lastReadChapterIndex == 1)
        #expect(loadedAgain.0.lastReadContentOffset == bodyStart + 2)
    }

    @Test func atomicImportPersistsChaptersAndRejectsDuplicateFilePath() async throws {
        let persistence = PersistenceController(inMemory: true)
        let bookRepository = BookRepository(context: persistence.container.newBackgroundContext())
        let chapterRepository = ChapterRepository(context: persistence.container.newBackgroundContext())
        let filePath = "/tmp/atomic-import-\(UUID().uuidString).txt"
        let book = Book(title: "原子导入", filePath: filePath, format: .txt)
        let chapters = [
            Chapter(index: 0, title: "第一章", content: "正文一", startLocation: 0, length: 3),
            Chapter(index: 1, title: "第二章", content: "正文二", startLocation: 3, length: 3)
        ]

        let savedBook = try await publisherValue(bookRepository.addBook(book, chapters: chapters))
        let savedChapters = try await publisherValue(chapterRepository.getChapters(forBookId: book.id))

        #expect(savedBook == book)
        #expect(savedChapters.map(\.title) == ["第一章", "第二章"])

        let duplicate = Book(title: "重复导入", filePath: filePath, format: .txt)
        var duplicateWasRejected = false
        do {
            _ = try await publisherValue(bookRepository.addBook(duplicate, chapters: chapters))
            Issue.record("相同文件路径应被拒绝")
        } catch BookError.bookAlreadyExists {
            duplicateWasRejected = true
        } catch {
            Issue.record("重复导入返回了错误类型：\(error)")
        }

        #expect(duplicateWasRejected)
        #expect(try await publisherValue(bookRepository.getAllBooks()).count == 1)
    }

    @Test func legacyStoreMigratesWithoutLosingBooks() throws {
        let modelDirectoryURL = try #require(
            [Bundle.main, Bundle(for: BookEntity.self)]
                .compactMap { $0.url(forResource: "BookReader", withExtension: "momd") }
                .first
        )
        let legacyModel = try #require(
            NSManagedObjectModel(
                contentsOf: modelDirectoryURL.appendingPathComponent("BookReader.mom")
            )
        )
        let currentModel = try #require(
            NSManagedObjectModel(
                contentsOf: modelDirectoryURL.appendingPathComponent("BookReaderV3.mom")
            )
        )
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let storeURL = storeDirectory.appendingPathComponent("BookReader.sqlite")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let legacyCoordinator = NSPersistentStoreCoordinator(managedObjectModel: legacyModel)
        let legacyStore = try legacyCoordinator.addPersistentStore(
            type: .sqlite,
            at: storeURL
        )
        let legacyContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        legacyContext.persistentStoreCoordinator = legacyCoordinator
        try legacyContext.performAndWait {
            let book = NSEntityDescription.insertNewObject(
                forEntityName: "BookEntity",
                into: legacyContext
            )
            book.setValue(UUID(), forKey: "id")
            book.setValue("迁移前的书", forKey: "title")
            book.setValue("/tmp/legacy-store.txt", forKey: "filePath")
            book.setValue("txt", forKey: "format")
            book.setValue(Date(), forKey: "createdAt")
            book.setValue(Date(), forKey: "updatedAt")
            book.setValue("unread", forKey: "readingStatus")
            try legacyContext.save()
        }
        try legacyCoordinator.remove(legacyStore)

        let currentCoordinator = NSPersistentStoreCoordinator(managedObjectModel: currentModel)
        let migratedStore = try currentCoordinator.addPersistentStore(
            type: .sqlite,
            at: storeURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        )
        let currentContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        currentContext.persistentStoreCoordinator = currentCoordinator
        try currentContext.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "BookEntity")
            let migratedBooks = try currentContext.fetch(request)
            #expect(migratedBooks.count == 1)
            #expect(migratedBooks.first?.value(forKey: "title") as? String == "迁移前的书")
            #expect((migratedBooks.first?.value(forKey: "readingSessions") as? NSSet)?.count == 0)
        }
        try currentCoordinator.remove(migratedStore)
    }

    @Test func dashboardStatsAggregateBooksAndSummaryFromSameSessions() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = ReadingStatsRepository(context: persistence.container.newBackgroundContext())
        let firstBookId = UUID()
        let secondBookId = UUID()
        let now = Date()
        let sessions = [
            ReadingSession(
                bookId: firstBookId,
                bookTitle: "第一本",
                startTime: now.addingTimeInterval(-180),
                endTime: now.addingTimeInterval(-120)
            ),
            ReadingSession(
                bookId: firstBookId,
                bookTitle: "第一本",
                startTime: now.addingTimeInterval(-120),
                endTime: now
            ),
            ReadingSession(
                bookId: secondBookId,
                bookTitle: "第二本",
                startTime: now.addingTimeInterval(-30),
                endTime: now
            )
        ]

        for session in sessions {
            _ = try await publisherValue(repository.saveReadingSession(session))
        }

        let dashboard = try await publisherValue(repository.getDashboardStats())
        let statsByBook = Dictionary(uniqueKeysWithValues: dashboard.bookStats.map { ($0.bookId, $0) })

        #expect(dashboard.summary.totalReadingTime == 210)
        #expect(dashboard.summary.totalSessions == 3)
        #expect(dashboard.summary.totalBooksRead == 2)
        #expect(statsByBook[firstBookId]?.totalReadingTime == 180)
        #expect(statsByBook[firstBookId]?.sessionsCount == 2)
        #expect(statsByBook[secondBookId]?.totalReadingTime == 30)
    }

    @Test @MainActor func backgroundPauseExcludesTimeSpentAwayFromTheApp() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = ReadingStatsRepository(context: persistence.container.newBackgroundContext())
        var currentDate = Date()
        let tracker = ReadingTimeTracker(
            repository: repository,
            now: { currentDate },
            minimumSessionDuration: 5,
            notificationCenter: NotificationCenter()
        )

        tracker.startReading(bookId: UUID(), bookTitle: "计时测试")
        currentDate = currentDate.addingTimeInterval(2)
        tracker.pauseReading()
        currentDate = currentDate.addingTimeInterval(100)
        tracker.resumeReading()
        currentDate = currentDate.addingTimeInterval(6)
        tracker.stopReading()

        let sessions = try await publisherValue(repository.getAllSessions())
        #expect(sessions.count == 1)
        #expect(sessions.first?.duration == 6)
    }

    @Test @MainActor func successfulImportPublishesSavedBookWithoutReloading() async throws {
        let repository = RecordingBookRepository()
        let viewModel = LibraryViewModel(bookRepository: repository)
        let sourceURL = temporaryFileURL(name: "visible-after-import.txt")
        let booksDirectory = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Books", isDirectory: true)
        let destinationURL = booksDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try "第一章\n导入完成后应立即显示".write(to: sourceURL, atomically: true, encoding: .utf8)

        viewModel.importBook(from: sourceURL)
        for _ in 0..<200 where !viewModel.importSuccess {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.importSuccess)
        #expect(!viewModel.isImporting)
        #expect(viewModel.books.count == 1)
        #expect(viewModel.books.first?.filePath == destinationURL.path)
    }

    @Test @MainActor func batchImportUsesAtomicBookAndChapterWrites() async throws {
        let repository = RecordingBookRepository()
        let viewModel = LibraryViewModel(bookRepository: repository)
        let sourceURLs = [
            temporaryFileURL(name: "batch-first.txt"),
            temporaryFileURL(name: "batch-second.txt")
        ]
        let booksDirectory = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Books", isDirectory: true)
        let destinationURLs = sourceURLs.map {
            booksDirectory.appendingPathComponent($0.lastPathComponent)
        }
        defer {
            (sourceURLs + destinationURLs).forEach { try? FileManager.default.removeItem(at: $0) }
        }
        try "第一章\n第一本".write(to: sourceURLs[0], atomically: true, encoding: .utf8)
        try "第一章\n第二本".write(to: sourceURLs[1], atomically: true, encoding: .utf8)

        viewModel.importBooks(from: sourceURLs)
        for _ in 0..<300 where viewModel.isBatchImporting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!viewModel.isBatchImporting)
        #expect(viewModel.batchImportSuccessCount == 2)
        #expect(viewModel.batchImportFailCount == 0)
        #expect(repository.atomicAddBookCallCount == 2)
        #expect(repository.plainAddBookCallCount == 0)
        #expect(viewModel.books.count == 2)
    }

    @Test @MainActor func batchImportRetriesSameNameAfterFailureAndCountsAllSelections() async throws {
        let repository = RecordingBookRepository()
        let viewModel = LibraryViewModel(bookRepository: repository)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderBatchRetry-\(UUID().uuidString)", isDirectory: true)
        let filename = "retry-\(UUID().uuidString).txt"
        let missingURL = sourceRoot.appendingPathComponent("missing/").appendingPathComponent(filename)
        let validURL = sourceRoot.appendingPathComponent("valid/").appendingPathComponent(filename)
        let unsupportedURL = sourceRoot.appendingPathComponent("unsupported.bin")
        let booksDirectory = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Books", isDirectory: true)
        let destinationURL = booksDirectory.appendingPathComponent(filename)
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.createDirectory(
            at: validURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "第一章\n有效的第二份".write(to: validURL, atomically: true, encoding: .utf8)

        viewModel.importBooks(from: [missingURL, validURL, unsupportedURL])
        for _ in 0..<300 where viewModel.isBatchImporting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!viewModel.isBatchImporting)
        #expect(viewModel.batchImportTotal == 3)
        #expect(viewModel.batchImportCurrent == 3)
        #expect(viewModel.batchImportSuccessCount == 1)
        #expect(viewModel.batchImportFailCount == 2)
        #expect(repository.atomicAddBookCallCount == 1)
        #expect(viewModel.books.first?.filePath == destinationURL.path)
    }

    @Test @MainActor func batchImportSkipsSameNameAfterSuccessfulImport() async throws {
        let repository = RecordingBookRepository()
        let viewModel = LibraryViewModel(bookRepository: repository)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderBatchDuplicate-\(UUID().uuidString)", isDirectory: true)
        let filename = "duplicate-\(UUID().uuidString).txt"
        let firstURL = sourceRoot.appendingPathComponent("first/").appendingPathComponent(filename)
        let secondURL = sourceRoot.appendingPathComponent("second/").appendingPathComponent(filename)
        let booksDirectory = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Books", isDirectory: true)
        let destinationURL = booksDirectory.appendingPathComponent(filename)
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationURL)
        }
        for url in [firstURL, secondURL] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "第一章\n正文".write(to: url, atomically: true, encoding: .utf8)
        }

        viewModel.importBooks(from: [firstURL, secondURL])
        for _ in 0..<300 where viewModel.isBatchImporting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!viewModel.isBatchImporting)
        #expect(viewModel.batchImportTotal == 2)
        #expect(viewModel.batchImportCurrent == 2)
        #expect(viewModel.batchImportSuccessCount == 1)
        #expect(viewModel.batchImportFailCount == 1)
        #expect(repository.atomicAddBookCallCount == 1)
        #expect(viewModel.books.count == 1)
    }

    @Test @MainActor func aSecondBatchWaitsForTheActiveImportInsteadOfBeingDropped() async throws {
        let repository = RecordingBookRepository()
        repository.shouldDelayNextAtomicImport = true
        let viewModel = LibraryViewModel(bookRepository: repository)
        let firstURL = temporaryFileURL(name: "queued-first.txt")
        let secondURL = temporaryFileURL(name: "queued-second.txt")
        let sourceURLs = [firstURL, secondURL]
        let booksDirectory = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Books", isDirectory: true)
        let destinationURLs = sourceURLs.map {
            booksDirectory.appendingPathComponent($0.lastPathComponent)
        }
        defer {
            (sourceURLs + destinationURLs).forEach { try? FileManager.default.removeItem(at: $0) }
        }
        try "第一章\n先导入".write(to: firstURL, atomically: true, encoding: .utf8)
        try "第一章\n排队导入".write(to: secondURL, atomically: true, encoding: .utf8)

        viewModel.importBooks(from: [firstURL])
        for _ in 0..<300 where repository.atomicAddBookCallCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(repository.atomicAddBookCallCount == 1)

        viewModel.importBooks(from: [secondURL])
        repository.completeDelayedAtomicImport()
        for _ in 0..<300 where viewModel.isBatchImporting || repository.atomicAddBookCallCount < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(repository.atomicAddBookCallCount == 2)
        #expect(viewModel.books.count == 2)
        #expect(viewModel.books.contains { $0.title.contains("queued-second") })
    }

    @Test @MainActor func importFinishingWithoutASavedBookDoesNotRemainStuck() async throws {
        let repository = RecordingBookRepository()
        repository.shouldFinishAtomicImportWithoutValue = true
        let viewModel = LibraryViewModel(bookRepository: repository)
        let sourceURL = temporaryFileURL(name: "empty-save-result.txt")
        let booksDirectory = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Books", isDirectory: true)
        let destinationURL = booksDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try "第一章\n保存链路异常".write(to: sourceURL, atomically: true, encoding: .utf8)

        viewModel.importBook(from: sourceURL)
        for _ in 0..<200 where viewModel.isImporting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!viewModel.isImporting)
        #expect(viewModel.error != nil)
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test @MainActor func singlePageBookHasFiniteCompletedProgress() {
        let repository = RecordingBookRepository()
        let book = Book(title: "短篇", filePath: "/tmp/short.txt", format: .txt)
        let viewModel = ReaderViewModel(book: book, bookRepository: repository)
        viewModel.chapters = [Chapter(index: 0, title: "正文", content: "短篇")]
        viewModel.pages = [
            Page(
                globalIndex: 0,
                content: "短篇",
                chapterIndex: 0,
                chapterTitle: "正文",
                isChapterStart: true,
                contentOffset: 0
            )
        ]

        viewModel.jumpToProgress(0.5)
        viewModel.flushProgress()

        #expect(viewModel.readingProgress == 1)
        #expect(viewModel.readingProgress.isFinite)
        #expect(repository.savedCompletionValues == [true])
    }

    @Test @MainActor func immediateFlushAfterPageTurnSavesLatestLocation() {
        let repository = RecordingBookRepository()
        let book = Book(title: "翻页退出", filePath: "/tmp/page-turn.txt", format: .txt)
        let viewModel = ReaderViewModel(book: book, bookRepository: repository)
        viewModel.chapters = [
            Chapter(index: 0, title: "一", content: "开篇"),
            Chapter(index: 1, title: "二", content: "甲乙丙丁戊己")
        ]
        viewModel.pages = [
            Page(globalIndex: 0, content: "开篇", chapterIndex: 0, chapterTitle: "一", isChapterStart: true, contentOffset: 0),
            Page(globalIndex: 1, content: "甲乙丙丁戊", chapterIndex: 1, chapterTitle: "二", isChapterStart: true, contentOffset: 0),
            Page(globalIndex: 2, content: "己", chapterIndex: 1, chapterTitle: "二", isChapterStart: false, contentOffset: 5)
        ]

        viewModel.updateProgressForPage(2)
        viewModel.flushProgress()

        #expect(repository.savedProgressLocations.count == 1)
        #expect(repository.savedProgressLocations.first?.chapterIndex == 1)
        #expect(repository.savedProgressLocations.first?.contentOffset == 5)
        #expect(repository.savedCompletionValues == [true])
    }

    private func temporaryFileURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderTests-\(UUID().uuidString)-\(name)")
    }

    private func makeDescriptor(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat = 844
    ) -> PageCacheDescriptor {
        PageCacheDescriptor(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            fontName: "System",
            fontSize: 18,
            lineSpacing: 8,
            paragraphSpacing: 0,
            horizontalPadding: 20,
            headerHeight: 28,
            contentTopPadding: 10,
            footerHeight: 30,
            sourceModificationTime: 1_000
        )
    }

    private func lastLineBottom(in frame: CTFrame, lines: [CTLine]) -> CGFloat {
        guard let lastLine = lines.last else { return 0 }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        CTLineGetTypographicBounds(lastLine, &ascent, &descent, &leading)
        return origins[lines.count - 1].y - descent
    }

    private func publisherValue<Output>(
        _ publisher: AnyPublisher<Output, Error>
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = publisher.first().sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        continuation.resume(throwing: error)
                    }
                    cancellable?.cancel()
                },
                receiveValue: { value in
                    continuation.resume(returning: value)
                    cancellable?.cancel()
                }
            )
        }
    }
}

private final class WiFiReceivedFilesRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var fileURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func capture(_ notification: Notification) {
        guard let fileURLs = notification.userInfo?[WiFiTransferNotificationKey.fileURLs] as? [URL] else {
            return
        }
        lock.lock()
        urls.append(contentsOf: fileURLs)
        lock.unlock()
    }
}

private final class WiFiConnectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var closed = false

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func markReady() {
        lock.lock()
        ready = true
        lock.unlock()
    }

    func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

private struct StubBookParser: BookChapterParsing {
    let chapters: [Chapter]

    func parseChapters(fileURL: URL) throws -> [Chapter] {
        chapters
    }
}

private final class RecordingBookRepository: BookRepositoryProtocol {
    var savedCompletionValues: [Bool] = []
    var savedProgressLocations: [(chapterIndex: Int, contentOffset: Int)] = []
    var shouldFinishAtomicImportWithoutValue = false
    var shouldDelayNextAtomicImport = false
    private(set) var plainAddBookCallCount = 0
    private(set) var atomicAddBookCallCount = 0
    private var delayedAtomicImport: (subject: PassthroughSubject<Book, Error>, book: Book)?

    func getAllBooks() -> AnyPublisher<[Book], Error> {
        success([])
    }

    func getBook(byId id: UUID) -> AnyPublisher<Book?, Error> {
        success(nil)
    }

    func addBook(_ book: Book) -> AnyPublisher<Book, Error> {
        plainAddBookCallCount += 1
        return success(book)
    }

    func addBook(_ book: Book, chapters: [Chapter]) -> AnyPublisher<Book, Error> {
        atomicAddBookCallCount += 1
        if shouldFinishAtomicImportWithoutValue {
            return Empty(completeImmediately: true).eraseToAnyPublisher()
        }
        if shouldDelayNextAtomicImport {
            shouldDelayNextAtomicImport = false
            let subject = PassthroughSubject<Book, Error>()
            delayedAtomicImport = (subject, book)
            return subject.eraseToAnyPublisher()
        }
        return success(book)
    }

    func completeDelayedAtomicImport() {
        guard let delayedAtomicImport else { return }
        self.delayedAtomicImport = nil
        delayedAtomicImport.subject.send(delayedAtomicImport.book)
        delayedAtomicImport.subject.send(completion: .finished)
    }

    func updateBook(_ book: Book) -> AnyPublisher<Book, Error> {
        success(book)
    }

    func deleteBook(byId id: UUID) -> AnyPublisher<Void, Error> {
        success(())
    }

    func searchBooks(query: String) -> AnyPublisher<[Book], Error> {
        success([])
    }

    func getFavoriteBooks() -> AnyPublisher<[Book], Error> {
        success([])
    }

    func getRecentlyReadBooks(limit: Int) -> AnyPublisher<[Book], Error> {
        success([])
    }

    func updateReadingProgress(
        bookId: UUID,
        chapterIndex: Int,
        contentOffset: Int,
        isCompleted: Bool
    ) -> AnyPublisher<Void, Error> {
        savedCompletionValues.append(isCompleted)
        savedProgressLocations.append((chapterIndex, contentOffset))
        return success(())
    }

    func toggleFavorite(bookId: UUID) -> AnyPublisher<Bool, Error> {
        success(true)
    }

    private func success<Output>(_ output: Output) -> AnyPublisher<Output, Error> {
        Just(output)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
}
