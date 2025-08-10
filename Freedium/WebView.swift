//
//  WebView.swift
//  Dream
//
//  Created by Assistant on 8/9/25.
//

import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

struct WebView: View {
    let url: URL
    var onArticleLink: ((URL) -> Void)? = nil

    var body: some View {
        WebViewRepresentable(url: url, onArticleLink: onArticleLink)
            .ignoresSafeArea()
    }
}

// MARK: - Coordinator shared between platforms
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let onArticleLink: ((URL) -> Void)?
    init(onArticleLink: ((URL) -> Void)?) { self.onArticleLink = onArticleLink }

    // Detect Medium article links
    private func isMediumArticleURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }

        let host = (url.host ?? "").lowercased()
        let path = url.path

        // Ignore obvious non-article paths
        if path == "/" { return false }
        if path.hasPrefix("/m/") || path.hasPrefix("/signin") || path.hasPrefix("/oauth") { return false }

        // Pattern 1: /p/<12+ hex id>
        let comps = path.split(separator: "/").map(String.init)
        if comps.count >= 2, comps[0] == "p" {
            let id = comps[1]
            let isHex = id.range(of: "^[0-9a-fA-F]{10,}$", options: .regularExpression) != nil
            if isHex { return true }
        }

        // Pattern 2: slug-<id> at end (id 10+ alnum), common across medium.com and publications (e.g., *.pub, *.com under Medium)
        if let last = path.split(separator: "/").last {
            let lastStr = String(last)
            if let dashIdx = lastStr.lastIndex(of: "-") {
                let id = lastStr[lastStr.index(after: dashIdx)...]
                if id.count >= 10 && id.range(of: "^[0-9a-zA-Z]+$", options: .regularExpression) != nil {
                    return true
                }
            }
        }

        // Allow short redirect hosts commonly used by Medium
        if host.contains("link.medium.com") { return true }

        return false
    }

    private func proxiedFreediumURL(for url: URL) -> URL {
        URL(string: "https://freedium.cfd/" + url.absoluteString) ?? url
    }

    // Receive link taps from injected JS (for SPA navigations)
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "linkTap", let href = message.body as? String, let url = URL(string: href) else { return }
        if isMediumArticleURL(url) {
            DispatchQueue.main.async { [weak self, onArticleLink] in
                guard let self else { return }
                onArticleLink?(self.proxiedFreediumURL(for: url))
            }
        }
    }

    // Ensure target=_blank opens in the same web view
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == false,
           let url = navigationAction.request.url {
            if isMediumArticleURL(url) {
                DispatchQueue.main.async { [weak self, onArticleLink] in
                    guard let self else { return }
                    onArticleLink?(self.proxiedFreediumURL(for: url))
                }
                decisionHandler(.cancel)
                return
            }
            // For other popups, open in same view
            webView.load(URLRequest(url: url))
            decisionHandler(.cancel)
            return
        }

        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() {
            if scheme != "http" && scheme != "https" {
                #if os(iOS)
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                #elseif os(macOS)
                NSWorkspace.shared.open(url)
                #endif
                decisionHandler(.cancel)
                return
            }
        }

        // Main-frame: intercept Medium article clicks and surface via callback
        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame == true {
            // Follow redirects for short linker domains
            var candidate = url
            if let host = url.host?.lowercased(), host.contains("link.medium.com"), let final = URL(string: url.absoluteString) {
                candidate = final
            }
            if isMediumArticleURL(candidate) {
                DispatchQueue.main.async { [weak self, onArticleLink] in
                    guard let self else { return }
                    onArticleLink?(self.proxiedFreediumURL(for: candidate))
                }
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    // Ensure content JavaScript stays enabled on a per-navigation basis (macOS 11+/iOS 14+)
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = true
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("WKWebView didFail navigation: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("WKWebView didFail provisional: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // Handle window.open
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, navigationAction.targetFrame == nil else { return nil }
        webView.load(URLRequest(url: url))
        return nil
    }
}

#if os(iOS)
// MARK: - iOS
struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    let onArticleLink: ((URL) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Persist cookies, sessions, and other site data across launches
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.allowsInlineMediaPlayback = true

        // Inject JS to capture link clicks for SPA/JS-driven navigations
        let userContent = configuration.userContentController
        userContent.add(UserContentProxy(coordinator: context.coordinator), name: "linkTap")
        let js = """
        (function(){
          function handler(e){
            var a=e.target.closest('a[href]');
            if(!a) return;
            var href=a.href;
            try { window.webkit.messageHandlers.linkTap.postMessage(href); } catch(e) {}
          }
          document.addEventListener('click', handler, true);
        })();
        """
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        userContent.addUserScript(script)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // Use a modern Safari user agent to avoid UA-based blocks
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/605.1.15"
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No-op. If you want to navigate to a new URL, pass a new `url`.
    }

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator(onArticleLink: onArticleLink) }
}
#elseif os(macOS)
// MARK: - macOS
struct WebViewRepresentable: NSViewRepresentable {
    let url: URL
    let onArticleLink: ((URL) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default() // persist cookies & storage
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Inject JS to capture link clicks for SPA/JS-driven navigations
        let userContent = configuration.userContentController
        userContent.add(UserContentProxy(coordinator: context.coordinator), name: "linkTap")
        let js = """
        (function(){
          function handler(e){
            var a=e.target.closest('a[href]');
            if(!a) return;
            var href=a.href;
            try { window.webkit.messageHandlers.linkTap.postMessage(href); } catch(e) {}
          }
          document.addEventListener('click', handler, true);
        })();
        """
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        userContent.addUserScript(script)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // Use a modern Safari user agent to avoid UA-based blocks
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No-op
    }

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator(onArticleLink: onArticleLink) }
}
#endif

// Helper to avoid retaining cycles when adding script handlers
private final class UserContentProxy: NSObject, WKScriptMessageHandler {
    weak var coordinator: WebViewCoordinator?
    init(coordinator: WebViewCoordinator?) { self.coordinator = coordinator }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        coordinator?.userContentController(userContentController, didReceive: message)
    }
}


