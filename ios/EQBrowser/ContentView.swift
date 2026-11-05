import SwiftUI
import WebKit

struct ContentView: View {
    private let startURL = URL(string: "https://music.youtube.com")!

    var body: some View {
        EQWebView(url: startURL, eqScript: Self.loadEQScript())
            .ignoresSafeArea()
    }

    /// The same EQ used by the Mac app and the bookmarklet, bundled as `ytm-eq.js`.
    private static func loadEQScript() -> String {
        guard let url = Bundle.main.url(forResource: "ytm-eq", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            print("EQBrowser: ytm-eq.js is missing from the app bundle")
            return ""
        }
        return source
    }
}

struct EQWebView: UIViewRepresentable {
    let url: URL
    let eqScript: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true

        if !eqScript.isEmpty {
            let script = WKUserScript(
                source: eqScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(script)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Hosts the main frame may navigate to. Sign-in goes through Google, and
        /// playback goes through googlevideo / ytimg, so those stay allowed.
        private static let allowedSuffixes = [
            "youtube.com", "youtu.be", "google.com", "gstatic.com",
            "googlevideo.com", "ytimg.com", "googleusercontent.com",
        ]

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Only restrict top-level navigation so embedded frames keep working.
            guard navigationAction.targetFrame?.isMainFrame == true else {
                decisionHandler(.allow)
                return
            }
            guard let host = navigationAction.request.url?.host?.lowercased() else {
                decisionHandler(.cancel)
                return
            }
            let allowed = Self.allowedSuffixes.contains { suffix in
                host == suffix || host.hasSuffix("." + suffix)
            }
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}
