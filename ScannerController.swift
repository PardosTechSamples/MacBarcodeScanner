import AppKit
import WebKit
import UniformTypeIdentifiers

final class ScanJob {
    let id = UUID().uuidString
    let sourceURL: URL?
    let sourceData: Data?
    let filename: String
    var status = "pending"
    var barcodes: [DetectedBarcode] = []
    var previewWidth = 0
    var previewHeight = 0
    var jpegFile: URL?
    var errorMessage: String?

    init(url: URL) {
        sourceURL = url
        sourceData = nil
        filename = url.lastPathComponent
    }

    init(filename: String, data: Data) {
        sourceURL = nil
        sourceData = data
        self.filename = filename
    }
}

final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    var jpegFileForID: ((String) -> URL?)?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(ScannerError.unreadableImage)
            return
        }

        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let file = jpegFileForID?(id),
              let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(ScannerError.unreadableImage)
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: "image/jpeg",
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

final class FileDropWebView: WKWebView {
    var onDroppedURLs: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDroppedURLs?(urls)
        return true
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL]) ?? []
    }
}

final class ScannerController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    private let schemeHandler = ImageSchemeHandler()
    private var window: NSWindow!
    private var webView: FileDropWebView!
    private var jobs: [ScanJob] = []
    private var selectedID: String?
    private var batchToken = 0
    private var isScanning = false
    private var ready = false
    private var pendingURLs: [URL] = []
    private var cacheDirectory: URL?

    func start() {
        buildWindow()
        loadUI()
        window.makeKeyAndOrderFront(nil)
    }

    func scan(url: URL) {
        add(urls: [url])
    }

    func add(urls: [URL]) {
        let images = Self.collectImages(from: urls)
        guard !images.isEmpty else { return }
        if ready {
            enqueue(images.map { ScanJob(url: $0) })
        } else {
            pendingURLs.append(contentsOf: images)
        }
    }

    @objc func openImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .heif]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose images or a folder (JPEG, PNG, HEIC)"
        panel.prompt = "Import"
        panel.begin { [weak self] result in
            guard result == .OK else { return }
            self?.add(urls: panel.urls)
        }
    }

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "scanner-image")
        config.userContentController.add(self, name: "scanner")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = FileDropWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860), configuration: config)
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.registerForDraggedTypes([.fileURL])
        webView.onDroppedURLs = { [weak self] urls in
            self?.add(urls: urls)
        }
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        schemeHandler.jpegFileForID = { [weak self] id in
            self?.jobs.first(where: { $0.id == id })?.jpegFile
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BarcodeScanner"
        window.minSize = NSSize(width: 900, height: 640)
        window.contentView = webView
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("BarcodeScannerWindow")
    }

    private func loadUI() {
        let htmlURL = Bundle.main.url(forResource: "app", withExtension: "html")
            ?? URL(fileURLWithPath: "Resources/app.html")
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            add(urls: urls)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }

        switch action {
        case "open":
            DispatchQueue.main.async { self.openImage(nil) }
        case "copy":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "copyBatch":
            copyBatchCSV()
        case "select":
            if let id = body["id"] as? String {
                selectJob(id: id)
            }
        case "clear":
            clearBatch()
        case "scanData":
            guard let filename = body["filename"] as? String,
                  let base64 = body["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            enqueue([ScanJob(filename: filename, data: data)])
        default:
            break
        }
    }

    private func enqueue(_ newJobs: [ScanJob]) {
        let existing = Set(jobs.compactMap { $0.sourceURL?.standardizedFileURL.path })
        let unique = newJobs.filter { job in
            guard let path = job.sourceURL?.standardizedFileURL.path else { return true }
            return !existing.contains(path) && !jobs.contains(where: { $0.filename == job.filename && $0.sourceURL?.path == path })
        }
        guard !unique.isEmpty else { return }

        jobs.append(contentsOf: unique)
        if selectedID == nil {
            selectedID = unique.first?.id
        }
        sendBatchSnapshot(status: "Queued \(unique.count) image(s).")
        pump()
    }

    private func pump() {
        guard !isScanning, let job = jobs.first(where: { $0.status == "pending" }) else {
            if !isScanning {
                let done = jobs.filter { $0.status == "done" }.count
                let total = jobs.count
                let codes = jobs.reduce(0) { $0 + $1.barcodes.count }
                if total > 0, done == total {
                    sendBatchSnapshot(status: "Finished \(total) image(s) · \(codes) barcode(s).", kind: "success")
                    refreshTitle()
                }
            }
            return
        }

        isScanning = true
        let token = batchToken
        job.status = "scanning"
        selectedID = selectedID ?? job.id
        let index = (jobs.firstIndex(where: { $0.id == job.id }) ?? 0) + 1
        sendBatchSnapshot(status: "Scanning \(job.filename) (\(index)/\(jobs.count))…")
        refreshTitle()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let loaded: LoadedImage
                if let url = job.sourceURL {
                    loaded = try ImageLoader.load(from: url)
                } else if let data = job.sourceData {
                    loaded = try ImageLoader.load(from: data)
                } else {
                    throw ScannerError.unreadableImage
                }

                let barcodes = VisionScanner.detect(in: loaded)
                let preview = ImageLoader.resized(loaded.display, maxEdge: 2200)
                let scale = Double(preview.width) / Double(max(loaded.display.width, 1))
                guard let jpeg = ImageLoader.jpegData(from: preview, quality: 0.82) else {
                    throw ScannerError.unreadableImage
                }
                let file = try self.writeJPEG(jpeg, id: job.id)

                DispatchQueue.main.async {
                    guard token == self.batchToken else { return }
                    job.status = "done"
                    job.barcodes = barcodes.map { Self.scaledBarcode($0, scale: scale) }
                    job.previewWidth = preview.width
                    job.previewHeight = preview.height
                    job.jpegFile = file
                    self.isScanning = false
                    self.sendResult(job)
                    self.sendBatchSnapshot(status: nil)
                    self.pump()
                }
            } catch {
                DispatchQueue.main.async {
                    guard token == self.batchToken else { return }
                    job.status = "error"
                    job.errorMessage = error.localizedDescription
                    self.isScanning = false
                    self.sendBatchSnapshot(status: "Error in \(job.filename): \(error.localizedDescription)", kind: "error")
                    self.pump()
                }
            }
        }
    }

    private func selectJob(id: String) {
        selectedID = id
        sendBatchSnapshot(status: nil)
        if let job = jobs.first(where: { $0.id == id }), job.status == "done" {
            sendResult(job)
        }
        refreshTitle()
    }

    private func clearBatch() {
        batchToken += 1
        isScanning = false
        jobs = []
        selectedID = nil
        if let cacheDirectory {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        cacheDirectory = nil
        window.title = "BarcodeScanner"
        send([
            "type": "cleared"
        ])
    }

    private func copyBatchCSV() {
        var lines = ["filename,index,format,value"]
        for job in jobs where job.status == "done" {
            if job.barcodes.isEmpty {
                lines.append("\(Self.csv(job.filename)),0,,")
                continue
            }
            for (index, barcode) in job.barcodes.enumerated() {
                lines.append("\(Self.csv(job.filename)),\(index + 1),\(Self.csv(barcode.format)),\(Self.csv(barcode.rawValue))")
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func sendResult(_ job: ScanJob) {
        send([
            "type": "result",
            "id": job.id,
            "filename": job.filename,
            "width": job.previewWidth,
            "height": job.previewHeight,
            "imageURL": "scanner-image://preview/\(job.id)?t=\(Date().timeIntervalSince1970)",
            "barcodes": job.barcodes.map { barcode -> [String: Any] in
                [
                    "format": barcode.format,
                    "rawValue": barcode.rawValue,
                    "boundingBox": [
                        "x": barcode.boundingBox.x,
                        "y": barcode.boundingBox.y,
                        "width": barcode.boundingBox.width,
                        "height": barcode.boundingBox.height
                    ],
                    "cornerPoints": barcode.cornerPoints.map { ["x": $0.x, "y": $0.y] }
                ]
            }
        ])
    }

    private func sendBatchSnapshot(status: String?, kind: String = "loading") {
        let done = jobs.filter { $0.status == "done" }.count
        let total = jobs.count
        let codes = jobs.reduce(0) { $0 + $1.barcodes.count }
        var payload: [String: Any] = [
            "type": "batch",
            "scanned": done,
            "total": total,
            "barcodeCount": codes,
            "jobs": jobs.map { job -> [String: Any] in
                var item: [String: Any] = [
                    "id": job.id,
                    "filename": job.filename,
                    "status": job.status,
                    "count": job.barcodes.count
                ]
                if let error = job.errorMessage {
                    item["error"] = error
                }
                return item
            }
        ]
        if let selectedID {
            payload["selectedId"] = selectedID
        }
        if let status {
            payload["status"] = status
            payload["kind"] = jobs.contains(where: { $0.status == "scanning" || $0.status == "pending" }) ? "loading" : kind
        }
        send(payload)
    }

    private func refreshTitle() {
        let done = jobs.filter { $0.status == "done" }.count
        let total = jobs.count
        if let job = jobs.first(where: { $0.id == selectedID }) {
            window.title = total > 1
                ? "BarcodeScanner — \(job.filename) (\(done)/\(total))"
                : "BarcodeScanner — \(job.filename)"
        } else if total > 0 {
            window.title = "BarcodeScanner — \(done)/\(total)"
        } else {
            window.title = "BarcodeScanner"
        }
    }

    private func writeJPEG(_ data: Data, id: String) throws -> URL {
        if cacheDirectory == nil {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BarcodeScanner-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            cacheDirectory = dir
        }
        let file = cacheDirectory!.appendingPathComponent("\(id).jpg")
        try data.write(to: file, options: .atomic)
        return file
    }

    private func send(_ payload: [String: Any]) {
        let work = {
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            self.webView.evaluateJavaScript("window.scannerReceive && window.scannerReceive(\(json))") { _, error in
                if let error {
                    NSLog("JS evaluate error: \(error)")
                }
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private static func scaledBarcode(_ barcode: DetectedBarcode, scale: Double) -> DetectedBarcode {
        guard scale != 1 else { return barcode }
        return DetectedBarcode(
            format: barcode.format,
            rawValue: barcode.rawValue,
            boundingBox: PixelBox(
                x: barcode.boundingBox.x * scale,
                y: barcode.boundingBox.y * scale,
                width: barcode.boundingBox.width * scale,
                height: barcode.boundingBox.height * scale
            ),
            cornerPoints: barcode.cornerPoints.map { PixelPoint(x: $0.x * scale, y: $0.y * scale) }
        )
    }

    private static func csv(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    static func collectImages(from urls: [URL]) -> [URL] {
        let allowed: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
        var images: [URL] = []
        let fm = FileManager.default

        func consider(_ url: URL) {
            let ext = url.pathExtension.lowercased()
            if allowed.contains(ext) {
                images.append(url)
            }
        }

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let kids = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                kids.forEach(consider)
            } else {
                consider(url)
            }
        }

        return images.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
