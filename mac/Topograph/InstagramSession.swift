import SwiftUI
import WebKit

/// You, signed in to Instagram in a web view of the app's own. Its cookies stay in the app's web
/// store and are never read or sent anywhere else. Only `sessionid`'s presence is checked.
@MainActor
@Observable
final class InstagramSession {
    private(set) var isSignedIn = false

    func refresh() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        isSignedIn = cookies.contains { $0.name == "sessionid" && $0.domain.hasSuffix("instagram.com") && !$0.value.isEmpty }
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { $0.displayName.contains("instagram") })
        await refresh()
    }

    /// What the pipeline calls from its own thread: a post's page as you see it, or nil.
    nonisolated var pageReader: @Sendable (String) -> String? {
        { url in
            let done = DispatchSemaphore(value: 0)
            let result = PageResult()
            Task { @MainActor in
                let reader = PageReader()
                result.html = await reader.read(url)
                done.signal()
            }
            guard done.wait(timeout: .now() + 40) == .success else { return nil }
            return result.html
        }
    }

    private final class PageResult: @unchecked Sendable {
        var html: String?
    }
}

/// Loads one page in a web view nobody sees, waits for it to settle and hands back its HTML.
/// A page that sent you to the login screen counts as nothing.
@MainActor
private final class PageReader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var finished: CheckedContinuation<Void, Never>?

    func read(_ url: String) async -> String? {
        guard let address = URL(string: url) else { return nil }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), configuration: WKWebViewConfiguration())
        view.customUserAgent = nil
        view.navigationDelegate = self
        webView = view
        await withCheckedContinuation { continuation in
            finished = continuation
            view.load(URLRequest(url: address, timeoutInterval: 25))
        }
        // The page's own script fills in the picture after it loads.
        try? await Task.sleep(for: .seconds(2))
        defer { webView = nil }
        if view.url?.path.contains("/accounts/login") == true { return nil }
        // Post pages usually carry Open Graph tags. When one doesn't, the largest picture in the
        // post stands in for them, in the form the parser already reads.
        let script = """
        (() => {
          const html = document.documentElement.outerHTML;
          if (document.querySelector('meta[property="og:image"]')) return html;
          const pictures = [...document.querySelectorAll('article img, main img')].filter(i => i.naturalWidth >= 300);
          pictures.sort((a, b) => b.naturalWidth * b.naturalHeight - a.naturalWidth * a.naturalHeight);
          if (!pictures.length) return html;
          const escape = s => (s || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;');
          return '<meta property="og:image" content="' + escape(pictures[0].src) + '" />' +
                 '<meta property="og:description" content="' + escape(pictures[0].alt) + '" />' + html;
        })()
        """
        return try? await view.evaluateJavaScript(script) as? String
    }

    private func finish() {
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
}

/// Instagram's own login page, in a sheet. Topograph never sees what's typed into it.
struct InstagramSignIn: View {
    let session: InstagramSession
    let theme: Theme
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("sign in to instagram").font(PlexMono.font(.semibold, size: 13)).foregroundStyle(theme.ink.color)
                Spacer()
                Button(session.isSignedIn ? "done" : "cancel") { close() }.buttonStyle(KeyStyle(theme: theme, led: false))
            }
            .padding(12)
            LoginPage { Task { await session.refresh() } }
        }
        .frame(width: 520, height: 680)
        .background(theme.ground.color)
        .task {
            // Close by itself once you're in.
            while !Task.isCancelled, !session.isSignedIn {
                await session.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
            if session.isSignedIn { close() }
        }
    }

    private struct LoginPage: NSViewRepresentable {
        let changed: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }

        func makeNSView(context: Context) -> WKWebView {
            let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            view.navigationDelegate = context.coordinator
            if let url = URL(string: "https://www.instagram.com/accounts/login/") { view.load(URLRequest(url: url)) }
            return view
        }

        func updateNSView(_ view: WKWebView, context: Context) {}

        final class Coordinator: NSObject, WKNavigationDelegate {
            let changed: () -> Void
            init(changed: @escaping () -> Void) { self.changed = changed }
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { changed() }
        }
    }
}
