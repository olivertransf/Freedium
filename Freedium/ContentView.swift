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
    @AppStorage("freedium_preferDarkMode") private var preferDarkMode: Bool = false
    @State private var isShowingSettings = false
    @State private var reloadToken: Int = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WebView(url: URL(string: "https://medium.com")!, onArticleLink: { url in
                freediumURL = url
            }, preferDarkMode: preferDarkMode)
            .id(reloadToken)

            // Floating settings button
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.bottom, 22)
            .accessibilityLabel("Settings")
        }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(isAuthenticating ? "Signing in…" : "Sign in") {
                        startMediumSignIn()
                    }
                    .disabled(isAuthenticating)
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsSheet(preferDarkMode: $preferDarkMode, onReload: {
                    // Force recreate the WebView and navigate home
                    reloadToken &+= 1
                })
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            #if os(iOS)
            .fullScreenCover(isPresented: Binding(
                get: { freediumURL != nil },
                set: { if !$0 { freediumURL = nil } }
            )) {
                if let link = freediumURL {
                    PresentedArticleView(url: link) { freediumURL = nil }
                }
            }
            #else
            .sheet(isPresented: Binding(
                get: { freediumURL != nil },
                set: { if !$0 { freediumURL = nil } }
            ), onDismiss: { freediumURL = nil }) {
                if let link = freediumURL { WebView(url: link) }
            }
            #endif
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

// MARK: - Full-screen presented article view (iOS)
#if os(iOS)
struct PresentedArticleView: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            WebView(url: url)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { onClose() }
                            .fontWeight(.semibold)
                    }
                }
        }
    }
}
#endif

// MARK: - Settings
struct SettingsSheet: View {
    @Binding var preferDarkMode: Bool
    var onReload: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Appearance")) {
                    Toggle(isOn: $preferDarkMode) {
                        Text("Dark Mode for Medium Home")
                    }
                    Text("Experimental: If dark mode doesn’t apply immediately, try ‘Reload Home’.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        onReload()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Reload Home")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
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
