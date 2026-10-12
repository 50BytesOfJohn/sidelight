/// Why another app's list of sessions couldn't be read from its database.
public enum SessionIndexFailure: Error, Equatable, Sendable {
    /// No database: the app isn't installed, hasn't run, or keeps it somewhere not looked at.
    case noDatabase
    /// The database has no session list this version can read: an older or much newer version of the app.
    case unsupported
    /// The database couldn't be read right now, such as while the app rewrites it.
    case unreadable
}
