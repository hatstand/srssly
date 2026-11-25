import SrsslyCore
import SrsslyStore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A web view for reading: shows reader HTML with JavaScript off, serves
/// cached images and stylesheets through the `srssly-cache:` scheme, and
/// opens tapped links in the browser. The live page (`.url`) runs normally.
struct ReaderWebView: UIViewRepresentable {
    enum Content: Equatable {
        case html(String, base: URL?)
        case url(URL)
    }

    let content: Content
    let cache: OfflineCache?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(CacheSchemeHandler(cache: cache), forURLScheme: ReaderDocument.resourceScheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.dataDetectorTypes = [.link]
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.accessibilityIdentifier = "reader"
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.loaded != content else { return }
        coordinator.loaded = content
        switch content {
        case .html(let html, let base):
            coordinator.isLivePage = false
            web.loadHTMLString(html, baseURL: base)
        case .url(let url):
            coordinator.isLivePage = true
            web.load(URLRequest(url: url))
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: Content?
        var isLivePage = false

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences
        ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            // In the reader, a tapped link leaves for the browser rather than
            // replacing the article.
            if !isLivePage, navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                await UIApplication.shared.open(url)
                return (.cancel, preferences)
            }
            preferences.allowsContentJavaScript = isLivePage
            return (.allow, preferences)
        }
    }
}

/// Serves files from the offline cache to the reader.
@MainActor
final class CacheSchemeHandler: NSObject, WKURLSchemeHandler {
    let cache: OfflineCache?

    init(cache: OfflineCache?) {
        self.cache = cache
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let name = ReaderDocument.fileName(from: url), let cache,
              let data = try? Data(contentsOf: cache.resourcesDirectory.appending(path: name, directoryHint: .notDirectory))
        else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let ext = (name as NSString).pathExtension
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? Self.sniff(data)
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// For cached files whose URL had no extension.
    static func sniff(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if b.count >= 12, b[0..<4].elementsEqual("RIFF".utf8), b[8..<12].elementsEqual("WEBP".utf8) { return "image/webp" }
        return "application/octet-stream"
    }
}
