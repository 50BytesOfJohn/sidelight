import AppKit
import SidelightCore
import os

/// The outside things the app is built on: its configuration file, how it reaches OpenRouter and keeps accounts' keys, which
/// apps' windows it may move, and which data services may run. ``standard`` is the real thing; anything else stands in
/// for part of it, so the app can be tried out without touching someone's setup, keychain, account, data or windows.
struct AppComposition {
    var configurationFile = ConfigurationStore.defaultFileURL
    var openRouterTransport: OpenRouterService.Transport = { try await HTTP.send($0) }
    var runwareTransport: RunwareService.Transport = { try await HTTP.send($0) }
    /// How Docker widgets run `docker`; `nil` finds the CLI where it's installed.
    var dockerTransport: DockerService.Transport?
    /// Where App Launcher widgets learn which apps run; `nil` asks `NSWorkspace`.
    var appLauncherSource: AppLauncherService.Source?
    /// Where key accounts' secrets are kept.
    var accountSecrets = AccountSecrets.keychain
    /// Which apps' windows window avoidance may move, besides being regular or accessory apps other than Sidelight.
    var movesWindows: (NSRunningApplication) -> Bool = { _ in true }
    /// The kinds of widget whose data services may run, shown or previewed; `nil` for every kind. The others never
    /// start, so nothing they read (sessions, usage, calendars) is read.
    var serviceKinds: Set<WidgetKind>?

    static let standard = AppComposition()

    /// Where the stash is kept: in a `stash` folder beside the configuration, so debug builds and a configuration
    /// tried out in isolation keep their own, and anything else the stash needs later has a place.
    var stashFile: URL {
        configurationFile.deletingLastPathComponent().appending(path: "stash/items.json", directoryHint: .notDirectory)
    }

    /// What this launch runs on: ``standard``, except in a debug build launched with any of these arguments, for
    /// trying the app out in isolation.
    ///
    /// - `-SidelightConfigurationFile <path>`: another `config.json`.
    /// - `-SidelightMovesWindowsOf <bundle identifier>`: window avoidance moves only that app's windows.
    /// - `-SidelightKeychainService <service>`: accounts' keys live in other keychain items, under `<service>`.
    /// - `-SidelightOpenRouterURL <http://127.0.0.1:port/…>`: OpenRouter requests go to a server on this Mac instead.
    ///   Only `http` or `https` on a loopback address is accepted; anything else, or a request that can't be sent
    ///   there, fails rather than reach OpenRouter.
    /// - `-SidelightRunwareURL <http://127.0.0.1:port/…>`: Runware requests go to a server on this Mac instead, on
    ///   the same terms.
    /// - `-SidelightDockerCLI <path>`: Docker widgets run this instead of `docker`, such as a script that fakes it.
    /// - `-SidelightServiceKinds <kind,kind,…>`: only these kinds of widget's data services run, such as
    ///   `openRouter,railway` (see ``WidgetKind``). Names it doesn't know run nothing.
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
            composition.accountSecrets = .keychain(service: service)
        }
        if let text = arguments.string(forKey: "SidelightOpenRouterURL") {
            composition.openRouterTransport = loopbackTransport(text, api: OpenRouterAPI.baseURL, name: "OpenRouter")
        }
        if let text = arguments.string(forKey: "SidelightRunwareURL") {
            composition.runwareTransport = loopbackTransport(text, api: RunwareAPI.endpoint, name: "Runware")
        }
        if let path = arguments.string(forKey: "SidelightDockerCLI") {
            Log.app.notice("Docker widgets run \(path, privacy: .public)")
            composition.dockerTransport = .cli(URL(filePath: path, directoryHint: .notDirectory))
        }
        if let text = arguments.string(forKey: "SidelightServiceKinds") {
            composition.serviceKinds = serviceKinds(text)
        }
        if composition.configurationFile != AppComposition.standard.configurationFile {
            Log.app.notice("Using the configuration at \(composition.configurationFile.path, privacy: .public)")
        }
        #endif
        return composition
    }
}

#if DEBUG
extension AppComposition {
    /// Sends `name`'s requests, to its API at `api`, to the server at `text` on this Mac instead. Fails every
    /// request when `text` isn't a loopback URL: asked to stay on this Mac, nothing goes to the provider instead.
    private static func loopbackTransport(
        _ text: String, api: URL, name: String
    ) -> @Sendable (URLRequest) async throws -> HTTP.Response {
        guard let server = LoopbackServer(text, api: api) else {
            Log.app.error(
                "Not sending \(name, privacy: .public) requests: \(text, privacy: .public) isn't an http(s) URL on this Mac"
            )
            return { _ in throw URLError(.unsupportedURL) }
        }
        Log.app.notice("Sending \(name, privacy: .public) requests to \(server.base.absoluteString, privacy: .public)")
        return { request in
            guard let redirected = server.redirected(request) else {
                Log.app.error("Not sending a \(name, privacy: .public) request that can't go to the server on this Mac")
                throw URLError(.unsupportedURL)
            }
            return try await HTTP.send(redirected, delegate: LoopbackRedirects())
        }
    }

    /// The kinds named in `text`, separated by commas. A name that isn't a kind is left out, so it runs nothing.
    private static func serviceKinds(_ text: String) -> Set<WidgetKind> {
        var kinds = Set<WidgetKind>()
        for name in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            if let kind = WidgetKind(rawValue: name) {
                kinds.insert(kind)
            } else {
                Log.app.error("No widget kind named \(name, privacy: .public): its services don't run")
            }
        }
        let names = kinds.map(\.rawValue).sorted().joined(separator: ",")
        Log.app.notice("Running only the data services of these kinds of widget: \(names, privacy: .public)")
        return kinds
    }
}

/// A server on this Mac that a provider's requests go to instead, at ``base``: `http` or `https` on a loopback
/// address, with nothing but a path.
private nonisolated struct LoopbackServer: Sendable {
    /// Where the provider's API is, on the server: always ends in `/`.
    let base: URL
    /// Where the provider's API really is.
    let api: URL

    private static let hosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    init?(_ text: String, api: URL) {
        self.api = api
        guard var components = URLComponents(string: text), Self.isLoopback(components),
            components.user == nil, components.password == nil, components.query == nil, components.fragment == nil
        else { return nil }
        if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        guard let base = components.url else { return nil }
        self.base = base
    }

    static func isLoopback(_ components: URLComponents) -> Bool {
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host?.lowercased()
        else { return false }
        return hosts.contains(host)
    }

    /// `request` sent here instead: its path under the provider's API moved under ``base``, its query, method,
    /// headers and body kept. `nil` for a request that isn't to the provider's API, or that can't be sent here.
    func redirected(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url,
            let original = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let api = URLComponents(url: self.api, resolvingAgainstBaseURL: false),
            original.scheme == api.scheme, original.host == api.host, original.port == api.port,
            original.percentEncodedPath.hasPrefix(api.percentEncodedPath),
            var target = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        target.percentEncodedPath += original.percentEncodedPath.dropFirst(api.percentEncodedPath.count)
        target.percentEncodedQuery = original.percentEncodedQuery
        guard let redirected = target.url,
            let check = URLComponents(url: redirected, resolvingAgainstBaseURL: false), Self.isLoopback(check)
        else { return nil }
        var request = request
        request.url = redirected
        return request
    }
}

/// Follows a redirect only to another address on this Mac: the server there can't send a request on to OpenRouter,
/// or anywhere else. A refused redirect comes back as the answer.
private nonisolated final class LoopbackRedirects: NSObject, URLSessionTaskDelegate {
    // `@concurrent`, as Objective-C calls it: from URLSession's queue, with no caller's actor to run on.
    @concurrent
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            LoopbackServer.isLoopback(components)
        else { return nil }
        return request
    }
}
#endif
