//
//  ContentView.swift
//  Dream
//
//  Created by Oliver Tran on 8/9/25.
//

import SwiftUI
import WebKit
import AuthenticationServices

struct ContentView: View {
    @State private var isAuthenticating = false
    @State private var freediumURL: URL? = nil

    var body: some View {
        WebView(url: URL(string: "https://medium.com")!) { url in
            freediumURL = url
        }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(isAuthenticating ? "Signing in…" : "Sign in") {
                        startMediumSignIn()
                    }
                    .disabled(isAuthenticating)
                }
            }
            .sheet(isPresented: Binding(
                get: { freediumURL != nil },
                set: { if !$0 { freediumURL = nil } }
            ), onDismiss: { freediumURL = nil }) {
                if let link = freediumURL { WebView(url: link) }
            }
    }

    private func startMediumSignIn() {
        #if os(iOS) || os(macOS)
        guard let callbackScheme = URL(string: "https://medium.com/")?.scheme else { return }
        let authURL = URL(string: "https://medium.com/m/signin")!
        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { _, _ in
            isAuthenticating = false
        }
        isAuthenticating = true
        #if os(iOS)
        session.presentationContextProvider = ASPresentationAnchorProvider()
        #endif
        session.prefersEphemeralWebBrowserSession = false
        session.start()
        #endif
    }
}

// No Identifiable conformance needed; using isPresented sheet

#if os(iOS)
final class ASPresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? UIWindow()
    }
}
#endif

#Preview {
    ContentView()
}
