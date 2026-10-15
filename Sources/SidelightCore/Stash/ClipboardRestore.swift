import UniformTypeIdentifiers

/// Which clipboards Sidelight can put back exactly after borrowing the clipboard to copy a selection (see
/// `StashCapture`). Text in any form is plain data, written back byte for byte. Images, files, file promises and app
/// private formats aren't attempted: some are produced lazily by the app that copied them, so they could be slow to
/// read, missing once that app quits, or impossible to write back as they were, and the clipboard would come back
/// changed.
public enum ClipboardRestore {
    /// The first type, among the types of each item on the clipboard, that can't be put back exactly; `nil` when
    /// every one can, including on an empty clipboard.
    public static func unrestorableType(in itemTypes: [[String]]) -> String? {
        itemTypes.lazy.flatMap(\.self).first { !isRestorable($0) }
    }

    /// Whether an item's `type` that has no data can be left out of the copy put back. macOS lists plain text in
    /// other encodings (UTF-16) beside the plain text an app wrote, yet has no data for them until asked in a way
    /// a copy can't: written back without them, the item gets them again. Anything else missing would be lost.
    public static func canOmitUnreadable(_ type: String, besideReadable readableTypes: [String]) -> Bool {
        isPlainText(type) && readableTypes.contains(where: isPlainText)
    }

    private static func isPlainText(_ type: String) -> Bool {
        UTType(type).map { !$0.isDynamic && $0.conforms(to: .plainText) } ?? false
    }

    /// Text in any form (plain, RTF, HTML, source code), web links, and the markers clipboard tools agree on
    /// (nspasteboard.org: the app that copied, transient, concealed).
    static func isRestorable(_ type: String) -> Bool {
        if type.hasPrefix("org.nspasteboard.") || linkTypes.contains(type) { return true }
        // A dynamic type is some app's private format whose name macOS made up: never text, as far as it's known.
        guard let uniformType = UTType(type), !uniformType.isDynamic else { return false }
        return uniformType.conforms(to: .text)
    }

    /// A copied web link and its title. Not every URL: a file URL stands for a file.
    private static let linkTypes: Set = [UTType.url.identifier, "public.url-name"]
}
