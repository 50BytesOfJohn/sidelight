import SidelightCore

extension KeychainItem {
    /// The Railway API token someone saves in Sidelight.
    static let railwayToken = KeychainItem(
        service: "app.getsidelight.Sidelight.railway", account: "api-token", label: "Sidelight: Railway API token")
}
