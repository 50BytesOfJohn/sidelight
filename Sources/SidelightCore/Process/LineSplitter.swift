import Foundation

/// Accumulates a byte stream and splits it into newline-terminated lines.
public struct LineSplitter: Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends `chunk` and returns every line it completed, without the trailing `\n`. Empty lines are dropped.
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        guard let lastNewline = buffer.lastIndex(of: 0x0A) else { return [] }
        let lines = buffer[buffer.startIndex..<lastNewline].split(separator: 0x0A).map { Data($0) }
        buffer = Data(buffer[buffer.index(after: lastNewline)...])
        return lines
    }
}
