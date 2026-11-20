import AppKit
import Observation
import PDFKit
import WebKit

enum CanvasExportFormat {
    case pdf, zip

    var title: String { self == .pdf ? "导出一个 PDF" : "导出 ZIP（HTML + PNG + PDF）" }
}

@MainActor
@Observable
final class CanvasExportJob: Identifiable {
    let id = UUID()
    let name: String
    let boards: [Artboard]
    let format: CanvasExportFormat
    let kind: ProjectKind
    private let sharedCSS: String?
    private let prototype: CanvasPrototype?

    private(set) var completed: Set<Int> = []
    private(set) var failures: [Int: String] = [:]
    private(set) var renderingIndex: Int?
    private(set) var isRunning = false
    @ObservationIgnored private var files: [Int: CanvasExportRenderer.Files] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    init(name: String, page: DesignPage, kind: ProjectKind, format: CanvasExportFormat) {
        self.name = name
        boards = page.composedArtboards
        sharedCSS = page.sharedCSS
        prototype = page.prototype
        self.kind = kind
        self.format = format
    }

    var isComplete: Bool { completed.count == boards.count && !boards.isEmpty }

    func render() {
        guard !isRunning, !isComplete else { return }
        let pending = boards.indices.filter { !completed.contains($0) }
        failures.removeAll()
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                renderingIndex = nil
                isRunning = false
                task = nil
            }
            for index in pending {
                guard !Task.isCancelled else { break }
                renderingIndex = index
                do {
                    let output = try await CanvasExportRenderer.render(boards[index], kind: kind, png: format == .zip)
                    try Task.checkCancellation()
                    files[index] = output
                    completed.insert(index)
                } catch is CancellationError {
                    break
                } catch {
                    failures[index] = error.localizedDescription
                }
            }
        }
    }

    func cancel() { task?.cancel() }

    func save(to url: URL) async throws {
        guard isComplete else { throw CocoaError(.fileWriteUnknown) }
        let ordered = try boards.enumerated().map { index, board in
            guard let output = files[index] else { throw CocoaError(.fileWriteUnknown) }
            return (name: board.name, html: board.html, png: output.png, pdf: output.pdf)
        }
        let boards = boards
        let kind = kind
        let name = name
        let sharedCSS = sharedCSS
        let prototype = prototype
        let format = format
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            switch format {
            case .pdf:
                let document = PDFDocument()
                for (index, file) in ordered.enumerated() {
                    guard let page = PDFDocument(data: file.pdf)?.page(at: 0) else {
                        throw CanvasExportRenderer.RenderError.invalidPDF(file.name)
                    }
                    document.insert(page, at: index)
                }
                guard let data = document.dataRepresentation(), document.pageCount == ordered.count else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
            case .zip:
                let bundle = CanvasBundle.make(title: name, artboards: boards, kind: kind, prototype: prototype)
                try ExportService.makeZip(name: name, at: url) { folder in
                    try ExportService.writeCanvasZipContents(to: folder, bundle: bundle, sharedCSS: sharedCSS, boards: ordered)
                }
            }
        }.value
    }
}

@MainActor
enum CanvasExportRenderer {
    struct Files {
        let pdf: Data
        let png: Data?
    }

    nonisolated enum RenderError: LocalizedError {
        case timedOut, invalidSize, invalidPDF(String), invalidPNG

        var errorDescription: String? {
            switch self {
            case .timedOut: "画板加载超时。"
            case .invalidSize: "画板尺寸无效。"
            case .invalidPDF(let name): "「\(name)」未生成有效的单页 PDF。"
            case .invalidPNG: "未生成有效的 PNG。"
            }
        }
    }

    static func render(_ board: Artboard, kind: ProjectKind, png: Bool) async throws -> Files {
        guard board.width.isFinite, board.height.isFinite, board.width > 0, board.height > 0 else {
            throw RenderError.invalidSize
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let scripts = configuration.userContentController
        scripts.addUserScript(WKUserScript(source: EditorScript.errorHook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let fit = board.fitsContent(in: kind)
        if fit {
            scripts.addUserScript(WKUserScript(source: EditorScript.editor, injectionTime: .atDocumentEnd,
                                               forMainFrameOnly: true, in: .defaultClient))
        }
        let web = WKWebView(frame: CGRect(origin: .zero, size: board.frame.size), configuration: configuration)
        let loader = NavigationLoader(web)
        try await loader.load(board.html)
        if fit {
            let height = try await web.callAsyncJavaScript("""
                window.__ds.setMode('off');
                window.__ds.fitContent(true, vh);
                const b = document.body, style = getComputedStyle(b);
                return Math.ceil(Math.max(b.scrollHeight, b.offsetHeight)
                    + (parseFloat(style.marginTop) || 0) + (parseFloat(style.marginBottom) || 0));
                """, arguments: ["vh": board.viewportHeight], contentWorld: .defaultClient) as? Double
            if let height, height.isFinite { web.frame.size.height = min(max(height, board.viewportHeight), 30_000) }
        }
        try Task.checkCancellation()
        let pdfConfiguration = WKPDFConfiguration()
        pdfConfiguration.rect = web.bounds
        let data = try await web.pdf(configuration: pdfConfiguration)
        guard PDFDocument(data: data)?.pageCount == 1 else { throw RenderError.invalidPDF(board.name) }
        guard png else { return Files(pdf: data, png: nil) }
        try Task.checkCancellation()
        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = web.bounds
        snapshot.snapshotWidth = NSNumber(value: min(board.width, 8_192))
        let image = try await web.takeSnapshot(configuration: snapshot)
        guard let png = ImageUtil.pngData(image), !png.isEmpty else { throw RenderError.invalidPNG }
        return Files(pdf: data, png: png)
    }

    private final class NavigationLoader: NSObject, WKNavigationDelegate {
        private let web: WKWebView
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ web: WKWebView) {
            self.web = web
            super.init()
            web.navigationDelegate = self
        }

        func load(_ html: String) async throws {
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self?.finish(.failure(RenderError.timedOut))
            }
            defer {
                timeout.cancel()
                web.navigationDelegate = nil
                if Task.isCancelled { web.stopLoading() }
            }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    web.loadHTMLString(html, baseURL: ArtboardWebView.baseURL)
                }
            } onCancel: {
                Task { @MainActor in self.finish(.failure(CancellationError())) }
            }
        }

        private func finish(_ result: Result<Void, Error>) {
            let waiting = continuation
            continuation = nil
            waiting?.resume(with: result)
            if case .failure = result { web.stopLoading() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(.failure(error))
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(.failure(URLError(.networkConnectionLost)))
        }
    }
}
