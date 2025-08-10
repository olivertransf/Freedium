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
    var preferDarkMode: Bool = false

    var body: some View {
        WebViewRepresentable(url: url, onArticleLink: onArticleLink, preferDarkMode: preferDarkMode)
            .ignoresSafeArea()
    }
}

// MARK: - Coordinator shared between platforms
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let onArticleLink: ((URL) -> Void)?
    init(onArticleLink: ((URL) -> Void)?) { self.onArticleLink = onArticleLink }
    weak var boundWebView: WKWebView?

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
                // Navigate the underlying web view back to Medium home in the background
                if let home = URL(string: "https://medium.com") {
                    self.boundWebView?.load(URLRequest(url: home))
                }
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
                // Navigate the underlying web view back to Medium home in the background
                if let home = URL(string: "https://medium.com") {
                    webView.load(URLRequest(url: home))
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
                // Navigate the underlying web view back to Medium home in the background
                if let home = URL(string: "https://medium.com") {
                    webView.load(URLRequest(url: home))
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
    let preferDarkMode: Bool

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
        let initialHost = url.host?.lowercased() ?? ""
        let initialIsMedium = initialHost == "medium.com" || initialHost.hasSuffix(".medium.com")
        // Dark mode scripts (added only when preferDarkMode is true on Medium only)
        let forceDarkJS = #"""
        (function(){
          try{
            var h = (location.host||'').toLowerCase();
            var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
            if(!isMedium) return;
            window.__freediumDarkEnabled = true;
            var m = document.querySelector('meta[name="color-scheme"]');
            if(!m){ m = document.createElement('meta'); m.setAttribute('name','color-scheme'); document.head.appendChild(m); }
            m.setAttribute('content','dark');
            try { document.documentElement.style.colorScheme = 'dark'; } catch(e){}
            var style = document.createElement('style');
            style.id = 'freedium-dark-mode';
            style.textContent = `
              :root { color-scheme: dark; }
              html, body { background-color: #0b0b0d !important; color: #e6e6e6 !important; }
              a { color: #8ab4f8 !important; }
            `;
            if(!document.getElementById('freedium-dark-mode')){
              document.head.appendChild(style);
            }
          }catch(e){}
        })();
        """#
        let forceDarkEnhanceJS = #"""
        (function(){
          try{
            var h = (location.host||'').toLowerCase();
            var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
            if(!isMedium) return;
            function ensure(){
              var style = document.getElementById('freedium-dark-mode-2');
              if(!style){
                style = document.createElement('style');
                style.id = 'freedium-dark-mode-2';
                style.type = 'text/css';
                style.textContent = [
                  ':root { color-scheme: dark !important; }',
                  'html { background-color:#0b0b0d !important; filter: invert(1) hue-rotate(180deg) !important; }',
                  'body { background-color:transparent !important; color:#e6e6e6 !important; }',
                  'a { color:#8ab4f8 !important; }',
                  'img, picture, video, canvas, iframe, svg { filter: invert(1) hue-rotate(180deg) contrast(1) !important; }'
                ].join('\n');
                (document.head||document.documentElement).appendChild(style);
              }
            }
            ensure();
            try{
              var mo = new MutationObserver(function(){ if(window.__freediumDarkEnabled){ ensure(); } });
              mo.observe(document.documentElement, { childList:true, subtree:true });
              window.__freediumDarkMO = mo;
            }catch(e){}
          }catch(e){}
        })();
        """#
        if preferDarkMode && initialIsMedium {
            let forceDarkScript = WKUserScript(source: forceDarkJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            userContent.addUserScript(forceDarkScript)
            let forceDarkEnhanceScript = WKUserScript(source: forceDarkEnhanceJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            userContent.addUserScript(forceDarkEnhanceScript)
        }
        if initialIsMedium {
        let js = #"""
        (function(){
          try{
            var h=(location.host||'').toLowerCase();
            var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
            if(!isMedium) return;
            function handler(e){
              var a=e.target.closest('a[href]');
              if(!a) return;
              var href=a.href;
              try { window.webkit.messageHandlers.linkTap.postMessage(href); } catch(e) {}
            }
            document.addEventListener('click', handler, true);
          }catch(e){}
        })();
        """#
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        userContent.addUserScript(script)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.boundWebView = webView
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // Use a modern Safari user agent to avoid UA-based blocks
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/605.1.15"
        if #available(iOS 13.0, *) {
            let initialHost = url.host?.lowercased() ?? ""
            let initialIsMedium = initialHost == "medium.com" || initialHost.hasSuffix(".medium.com")
            webView.overrideUserInterfaceStyle = (preferDarkMode && initialIsMedium) ? .dark : .unspecified
        }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // React to dark mode toggle without recreating the web view
        if #available(iOS 13.0, *) {
            let currentHost = uiView.url?.host?.lowercased() ?? ""
            let isMedium = currentHost == "medium.com" || currentHost.hasSuffix(".medium.com")
            uiView.overrideUserInterfaceStyle = (preferDarkMode && isMedium) ? .dark : .unspecified
        }
        // Ensure future navigations get the right injection set
        let userContent = uiView.configuration.userContentController
        userContent.removeAllUserScripts()
        let currentHost = uiView.url?.host?.lowercased() ?? ""
        let isMedium = currentHost == "medium.com" || currentHost.hasSuffix(".medium.com")
        if isMedium {
        let linkTapJS = #"""
        (function(){
          try{
            var h=(location.host||'').toLowerCase();
            var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
            if(!isMedium) return;
            function handler(e){
              var a=e.target.closest('a[href]');
              if(!a) return;
              var href=a.href;
              try { window.webkit.messageHandlers.linkTap.postMessage(href); } catch(e) {}
            }
            document.addEventListener('click', handler, true);
          }catch(e){}
        })();
        """#
        let linkTapScript = WKUserScript(source: linkTapJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        userContent.addUserScript(linkTapScript)
        if preferDarkMode {
            let forceDarkJS = #"""
            (function(){
              try{
                var h = (location.host||'').toLowerCase();
                var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
                if(!isMedium) return;
                window.__freediumDarkEnabled = true;
                var m = document.querySelector('meta[name="color-scheme"]');
                if(!m){ m = document.createElement('meta'); m.setAttribute('name','color-scheme'); document.head.appendChild(m); }
                m.setAttribute('content','dark');
                try { document.documentElement.style.colorScheme = 'dark'; } catch(e){}
                var style = document.createElement('style');
                style.id = 'freedium-dark-mode';
                style.textContent = `
                  :root { color-scheme: dark; }
                  html, body { background-color: #0b0b0d !important; color: #e6e6e6 !important; }
                  a { color: #8ab4f8 !important; }
                `;
                if(!document.getElementById('freedium-dark-mode')){
                  document.head.appendChild(style);
                }
              }catch(e){}
            })();
            """#
            let forceDarkEnhanceJS = #"""
            (function(){
              try{
                var h = (location.host||'').toLowerCase();
                var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
                if(!isMedium) return;
                function ensure(){
                  var style = document.getElementById('freedium-dark-mode-2');
                  if(!style){
                    style = document.createElement('style');
                    style.id = 'freedium-dark-mode-2';
                    style.type = 'text/css';
                    style.textContent = [
                      ':root { color-scheme: dark !important; }',
                      'html { background-color:#0b0b0d !important; filter: invert(1) hue-rotate(180deg) !important; }',
                      'body { background-color:transparent !important; color:#e6e6e6 !important; }',
                      'a { color:#8ab4f8 !important; }',
                      'img, picture, video, canvas, iframe, svg { filter: invert(1) hue-rotate(180deg) contrast(1) !important; }'
                    ].join('\n');
                    (document.head||document.documentElement).appendChild(style);
                  }
                }
                ensure();
                try{
                  var mo = new MutationObserver(function(){ if(window.__freediumDarkEnabled){ ensure(); } });
                  mo.observe(document.documentElement, { childList:true, subtree:true });
                  window.__freediumDarkMO = mo;
                }catch(e){}
              }catch(e){}
            })();
            """#
            let forceDarkScript = WKUserScript(source: forceDarkJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            let forceDarkEnhanceScript = WKUserScript(source: forceDarkEnhanceJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            userContent.addUserScript(forceDarkScript)
            userContent.addUserScript(forceDarkEnhanceScript)
        }
        }
        if isMedium {
        let enableDark = #"""
        (function(){
          try{
            var h = (location.host||'').toLowerCase();
            var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
            if(!isMedium) return;
            function apply(){
              try{
                window.__freediumDarkEnabled = true;
                var headOrRoot = (document.head||document.documentElement);
                var m = document.querySelector('meta[name="color-scheme"]');
                if(!m){ m = document.createElement('meta'); m.setAttribute('name','color-scheme'); headOrRoot.appendChild(m); }
                m.setAttribute('content','dark');
                try { document.documentElement.style.colorScheme = 'dark'; } catch(e){}
                if(!document.getElementById('freedium-dark-mode')){
                  var style = document.createElement('style');
                  style.id = 'freedium-dark-mode';
                  style.textContent = ':root { color-scheme: dark; } html, body { background-color: #0b0b0d \!important; color: #e6e6e6 \!important; } a { color: #8ab4f8 \!important; }';
                  headOrRoot.appendChild(style);
                }
                if(!document.getElementById('freedium-dark-mode-2')){
                  var style2 = document.createElement('style');
                  style2.id = 'freedium-dark-mode-2';
                  style2.type = 'text/css';
                  style2.textContent = [
                    ':root { color-scheme: dark !important; }',
                    'html { background-color:#0b0b0d !important; filter: invert(1) hue-rotate(180deg) !important; }',
                    'body { background-color:transparent !important; color:#e6e6e6 !important; }',
                    'a { color:#8ab4f8 !important; }',
                    'img, picture, video, canvas, iframe, svg { filter: invert(1) hue-rotate(180deg) contrast(1) !important; }'
                  ].join('\n');
                  headOrRoot.appendChild(style2);
                }
                try{
                  if(!window.__freediumDarkMO){
                    var mo = new MutationObserver(function(){ if(window.__freediumDarkEnabled){ var s=document.getElementById('freedium-dark-mode-2'); if(!s){ var st=document.createElement('style'); st.id='freedium-dark-mode-2'; st.type='text/css'; st.textContent=[ ':root { color-scheme: dark !important; }', 'html { background-color:#0b0b0d !important; filter: invert(1) hue-rotate(180deg) !important; }', 'body { background-color:transparent !important; color:#e6e6e6 !important; }', 'a { color:#8ab4f8 !important; }', 'img, picture, video, canvas, iframe, svg { filter: invert(1) hue-rotate(180deg) contrast(1) !important; }' ].join('\n'); (document.head||document.documentElement).appendChild(st); } }});
                    mo.observe(document.documentElement, { childList:true, subtree:true });
                    window.__freediumDarkMO = mo;
                  }
                }catch(e){}
              }catch(e){}
            }
            // Apply immediately and after load, plus a short retry window
            apply();
            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', apply, { once: true });
            }
            setTimeout(apply, 100);
            setTimeout(apply, 300);
            setTimeout(apply, 800);
          }catch(e){}
        })();
        """#
        let disableDark = #"""
        (function(){
          try{
            var h = (location.host||'').toLowerCase();
            var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
            if(!isMedium) return;
            try{ var s=document.getElementById('freedium-dark-mode'); if(s) s.remove(); var s2=document.getElementById('freedium-dark-mode-2'); if(s2) s2.remove(); }catch(e){}
            try{ if(window.__freediumDarkMO){ window.__freediumDarkMO.disconnect(); window.__freediumDarkMO = null; } }catch(e){}
            window.__freediumDarkEnabled = false;
            var m = document.querySelector('meta[name="color-scheme"]');
            if(!m){ m = document.createElement('meta'); m.setAttribute('name','color-scheme'); document.head.appendChild(m); }
            m.setAttribute('content','light');
            try { document.documentElement.style.colorScheme = 'light'; } catch(e){}
          }catch(e){}
        })();
        """#
        uiView.evaluateJavaScript(preferDarkMode ? enableDark : disableDark, completionHandler: nil)
        }
    }

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator(onArticleLink: onArticleLink) }
}
#elseif os(macOS)
// MARK: - macOS
struct WebViewRepresentable: NSViewRepresentable {
    let url: URL
    let onArticleLink: ((URL) -> Void)?
    let preferDarkMode: Bool

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default() // persist cookies & storage
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Inject JS to capture link clicks for SPA/JS-driven navigations
        let userContent = configuration.userContentController
        userContent.add(UserContentProxy(coordinator: context.coordinator), name: "linkTap")
        let initialHost = url.host?.lowercased() ?? ""
        let initialIsMedium = initialHost == "medium.com" || initialHost.hasSuffix(".medium.com")
        // Dark mode scripts (added only when preferDarkMode is true on Medium only)
        let forceDarkJS = #"""
        (function(){
          try{
            var h = (location.host||'').toLowerCase();
            var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
            if(!isMedium) return;
            window.__freediumDarkEnabled = true;
            var m = document.querySelector('meta[name="color-scheme"]');
            if(!m){ m = document.createElement('meta'); m.setAttribute('name','color-scheme'); document.head.appendChild(m); }
            m.setAttribute('content','dark');
            try { document.documentElement.style.colorScheme = 'dark'; } catch(e){}
            var style = document.createElement('style');
            style.id = 'freedium-dark-mode';
            style.textContent = `
              :root { color-scheme: dark; }
              html, body { background-color: #0b0b0d !important; color: #e6e6e6 !important; }
              a { color: #8ab4f8 !important; }
            `;
            if(!document.getElementById('freedium-dark-mode')){
              document.head.appendChild(style);
            }
          }catch(e){}
        })();
        """#
        let forceDarkEnhanceJS = #"""
        (function(){
          try{
            var h = (location.host||'').toLowerCase();
            var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
            if(!isMedium) return;
            function ensure(){
              var style = document.getElementById('freedium-dark-mode-2');
              if(!style){
                style = document.createElement('style');
                style.id = 'freedium-dark-mode-2';
                style.type = 'text/css';
                style.textContent = [
                  ':root { color-scheme: dark !important; }',
                  'html { background-color:#0b0b0d !important; filter: invert(1) hue-rotate(180deg) !important; }',
                  'body { background-color:transparent !important; color:#e6e6e6 !important; }',
                  'a { color:#8ab4f8 !important; }',
                  'img, picture, video, canvas, iframe, svg { filter: invert(1) hue-rotate(180deg) contrast(1) !important; }'
                ].join('\n');
                (document.head||document.documentElement).appendChild(style);
              }
            }
            ensure();
            try{
              var mo = new MutationObserver(function(){ if(window.__freediumDarkEnabled){ ensure(); } });
              mo.observe(document.documentElement, { childList:true, subtree:true });
              window.__freediumDarkMO = mo;
            }catch(e){}
          }catch(e){}
        })();
        """#
        if preferDarkMode && initialIsMedium {
            let forceDarkScript = WKUserScript(source: forceDarkJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            userContent.addUserScript(forceDarkScript)
            let forceDarkEnhanceScript = WKUserScript(source: forceDarkEnhanceJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            userContent.addUserScript(forceDarkEnhanceScript)
        }
        if initialIsMedium {
        let js = #"""
        (function(){
          try{
            var h=(location.host||'').toLowerCase();
            var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
            if(!isMedium) return;
            function handler(e){
              var a=e.target.closest('a[href]');
              if(!a) return;
              var href=a.href;
              try { window.webkit.messageHandlers.linkTap.postMessage(href); } catch(e) {}
            }
            document.addEventListener('click', handler, true);
          }catch(e){}
        })();
        """#
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        userContent.addUserScript(script)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.boundWebView = webView
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // Use a modern Safari user agent to avoid UA-based blocks
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        #if os(macOS)
        // Force dark only for Medium pages; leave others to their native theme
        let initialHost = url.host?.lowercased() ?? ""
        let initialIsMedium = initialHost == "medium.com" || initialHost.hasSuffix(".medium.com")
        webView.appearance = (preferDarkMode && initialIsMedium) ? NSAppearance(named: .darkAqua) : nil
        #endif
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Toggle appearance only for Medium pages; reset to nil for others
        let currentHost = nsView.url?.host?.lowercased() ?? ""
        let isMedium = currentHost == "medium.com" || currentHost.hasSuffix(".medium.com")
        nsView.appearance = (preferDarkMode && isMedium) ? NSAppearance(named: .darkAqua) : nil

        // Ensure future navigations get the right injection set
        let userContent = nsView.configuration.userContentController
        userContent.removeAllUserScripts()
        let currentHost = nsView.url?.host?.lowercased() ?? ""
        let isMedium = currentHost == "medium.com" || currentHost.hasSuffix(".medium.com")
        if isMedium {
        let linkTapJS = #"""
        (function(){
          try{
            var h=(location.host||'').toLowerCase();
            var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
            if(!isMedium) return;
            function handler(e){
              var a=e.target.closest('a[href]');
              if(!a) return;
              var href=a.href;
              try { window.webkit.messageHandlers.linkTap.postMessage(href); } catch(e) {}
            }
            document.addEventListener('click', handler, true);
          }catch(e){}
        })();
        """#
        let linkTapScript = WKUserScript(source: linkTapJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        userContent.addUserScript(linkTapScript)
        if preferDarkMode {
            let forceDarkJS = #"""
            (function(){
              try{
                var h = (location.host||'').toLowerCase();
                var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
                if(!isMedium) return;
                window.__freediumDarkEnabled = true;
                var m = document.querySelector('meta[name="color-scheme"]');
                if(!m){ m = document.createElement('meta'); m.setAttribute('name','color-scheme'); document.head.appendChild(m); }
                m.setAttribute('content','dark');
                try { document.documentElement.style.colorScheme = 'dark'; } catch(e){}
                var style = document.createElement('style');
                style.id = 'freedium-dark-mode';
                style.textContent = `
                  :root { color-scheme: dark; }
                  html, body { background-color: #0b0b0d !important; color: #e6e6e6 !important; }
                  a { color: #8ab4f8 !important; }
                `;
                if(!document.getElementById('freedium-dark-mode')){
                  document.head.appendChild(style);
                }
              }catch(e){}
            })();
            """#
            let forceDarkEnhanceJS = #"""
            (function(){
              try{
                var h = (location.host||'').toLowerCase();
                var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
                if(!isMedium) return;
                function ensure(){
                  var style = document.getElementById('freedium-dark-mode-2');
                  if(!style){
                    style = document.createElement('style');
                    style.id = 'freedium-dark-mode-2';
                    style.type = 'text/css';
                    style.textContent = [
                      ':root { color-scheme: dark !important; }',
                      'html { background-color:#0b0b0d !important; filter: invert(1) hue-rotate(180deg) !important; }',
                      'body { background-color:transparent !important; color:#e6e6e6 !important; }',
                      'a { color:#8ab4f8 !important; }',
                      'img, picture, video, canvas, iframe, svg { filter: invert(1) hue-rotate(180deg) contrast(1) !important; }'
                    ].join('\n');
                    (document.head||document.documentElement).appendChild(style);
                  }
                }
                ensure();
                try{
                  var mo = new MutationObserver(function(){ if(window.__freediumDarkEnabled){ ensure(); } });
                  mo.observe(document.documentElement, { childList:true, subtree:true });
                  window.__freediumDarkMO = mo;
                }catch(e){}
              }catch(e){}
            })();
            """#
            let forceDarkScript = WKUserScript(source: forceDarkJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            let forceDarkEnhanceScript = WKUserScript(source: forceDarkEnhanceJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            userContent.addUserScript(forceDarkScript)
            userContent.addUserScript(forceDarkEnhanceScript)
        }
        }

        // Enable/disable injected CSS live
        if isMedium {
        let enableDark = #"""
        (function(){
          try{
            var h = (location.host||'').toLowerCase();
            var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
            if(!isMedium) return;
            function apply(){
              try{
                window.__freediumDarkEnabled = true;
                var headOrRoot = (document.head||document.documentElement);
                var m = document.querySelector('meta[name="color-scheme"]');
                if(!m){ m = document.createElement('meta'); m.setAttribute('name','color-scheme'); headOrRoot.appendChild(m); }
                m.setAttribute('content','dark');
                try { document.documentElement.style.colorScheme = 'dark'; } catch(e){}
                if(!document.getElementById('freedium-dark-mode')){
                  var style = document.createElement('style');
                  style.id = 'freedium-dark-mode';
                  style.textContent = ':root { color-scheme: dark; } html, body { background-color: #0b0b0d !important; color: #e6e6e6 !important; } a { color: #8ab4f8 !important; }';
                  headOrRoot.appendChild(style);
                }
                if(!document.getElementById('freedium-dark-mode-2')){
                  var style2 = document.createElement('style');
                  style2.id = 'freedium-dark-mode-2';
                  style2.type = 'text/css';
                  style2.textContent = [
                    ':root { color-scheme: dark !important; }',
                    'html { background-color:#0b0b0d !important; filter: invert(1) hue-rotate(180deg) !important; }',
                    'body { background-color:transparent !important; color:#e6e6e6 !important; }',
                    'a { color:#8ab4f8 !important; }',
                    'img, picture, video, canvas, iframe, svg { filter: invert(1) hue-rotate(180deg) contrast(1) !important; }'
                  ].join('\n');
                  headOrRoot.appendChild(style2);
                }
                try{
                  if(!window.__freediumDarkMO){
                    var mo = new MutationObserver(function(){ if(window.__freediumDarkEnabled){ var s=document.getElementById('freedium-dark-mode-2'); if(!s){ var st=document.createElement('style'); st.id='freedium-dark-mode-2'; st.type='text/css'; st.textContent=[ ':root { color-scheme: dark !important; }', 'html { background-color:#0b0b0d !important; filter: invert(1) hue-rotate(180deg) !important; }', 'body { background-color:transparent !important; color:#e6e6e6 !important; }', 'a { color:#8ab4f8 !important; }', 'img, picture, video, canvas, iframe, svg { filter: invert(1) hue-rotate(180deg) contrast(1) !important; }' ].join('\n'); (document.head||document.documentElement).appendChild(st); } }});
                    mo.observe(document.documentElement, { childList:true, subtree:true });
                    window.__freediumDarkMO = mo;
                  }
                }catch(e){}
              }catch(e){}
            }
            // Apply immediately and after load, plus a short retry window
            apply();
            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', apply, { once: true });
            }
            setTimeout(apply, 100);
            setTimeout(apply, 300);
            setTimeout(apply, 800);
          }catch(e){}
        })();
        """#
        let disableDark = #"""
        (function(){
          try{
            var h = (location.host||'').toLowerCase();
            var isMedium = h==="medium.com" || /\.medium\.com$/.test(h);
            if(!isMedium) return;
            try{ var s=document.getElementById('freedium-dark-mode'); if(s) s.remove(); var s2=document.getElementById('freedium-dark-mode-2'); if(s2) s2.remove(); }catch(e){}
            try{ if(window.__freediumDarkMO){ window.__freediumDarkMO.disconnect(); window.__freediumDarkMO = null; } }catch(e){}
            window.__freediumDarkEnabled = false;
            var m = document.querySelector('meta[name="color-scheme"]');
            if(!m){ m = document.createElement('meta'); m.setAttribute('name','color-scheme'); document.head.appendChild(m); }
            m.setAttribute('content','light');
            try { document.documentElement.style.colorScheme = 'light'; } catch(e){}
          }catch(e){}
        })();
        """#
        nsView.evaluateJavaScript(preferDarkMode ? enableDark : disableDark, completionHandler: nil)
        }
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


