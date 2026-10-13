import AppKit
import SidelightCore
import os

/// The outside things the app is built on: its configuration file, how it reaches OpenRouter and keeps the key, and
/// which apps' windows it may move. ``standard`` is the real thing; anything else stands in for part of it, so the app
/// can be tried out without touching someone's setup, keychain, account or windows.
struct AppComposition {
    var configurationFile = ConfigurationStore.defaultFileURL
    var openRouterTransport: OpenRouterService.Transport = { try await HTTP.send($0) }
    var openRouterKeyStore = OpenRouterKeyStore.keychain
    /// Which apps' windows window avoidance may move, besides being regular apps other than Sidelight.
    var movesWindows: (NSRunningApplication) -> Bool = { _ in true }

    static let standard = AppComposition()

    /// What this launch runs on: ``standard``, except in a debug build launched with any of these arguments, for
    /// trying the app out in isolation.
    ///
    /// - `-SidelightConfigurationFile <path>`: another `config.json`.
    /// - `-SidelightMovesWindowsOf <bundle identifier>`: window avoidance moves only that app's windows.
    /// - `-SidelightKeychainService <service>`: the OpenRouter key lives in another keychain item.
    /// - `-SidelightOpenRouterURL <http://127.0.0.1:port/…>`: OpenRouter requests go to a server on this Mac instead.
    ///   Only loopback addresses are accepted.
    static var launch: AppComposition {
        var composition = AppComposition.standard
        #if DEBUG
        let arguments = UserDefaults.standard
        if let path = arguments.string(forKey: "SidelightConfigurationFile") {
            composition.configurationFile = URL(filePath: path, directoryHint: .notDirectory)
        }
        if let bundleIdentifier = arguments.string(forKey: "SidelightMovesWindowsOf") {
            composition.movesWindows = { $0.bundleIdentifier == bundleIdentifier }
        }
        if let service = arguments.string(forKey: "SidelightKeychainService") {
            composition.openRouterKeyStore = .keychain(service: service)
        }
        if let text = arguments.string(forKey: "SidelightOpenRouterURL"), let base = URL(string: text),
            ["127.0.0.1", "localhost", "::1"].contains(base.host() ?? "")
        {
            composition.openRouterTransport = { request in
                try await HTTP.send(request.redirected(from: OpenRouterAPI.baseURL, to: base))
            }
        }
        if composition.configurationFile != AppComposition.standard.configurationFile {
            Log.app.notice("Using the configuration at \(composition.configurationFile.path, privacy: .public)")
        }
        #endif
        return composition
    }
}

#if DEBUG
extension URLRequest {
    /// This request, sent to `base` instead of `original`, path and query kept.
    fileprivate nonisolated func redirected(from original: URL, to base: URL) -> URLRequest {
        let prefix = original.absoluteString
        guard let url, url.absoluteString.hasPrefix(prefix),
            let redirected = URL(string: base.absoluteString + url.absoluteString.dropFirst(prefix.count))
        else { return self }
        var request = self
        request.url = redirected
        return request
    }
}
#endif
