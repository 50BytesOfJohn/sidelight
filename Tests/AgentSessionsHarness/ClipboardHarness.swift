import AppKit
import Foundation
import SQLite3

// Snapshot every pasteboard type only in process memory. Never print or persist the user's data.
let board = NSPasteboard.general
precondition(board.changeCount >= 0, "System pasteboard unavailable in this shell sandbox; stop before UI copies")
let original = (board.pasteboardItems ?? []).map { item in
    let copy = NSPasteboardItem()
    for type in item.types {
        if let data = item.data(forType: type) { copy.setData(data, forType: type) }
    }
    return copy
}
guard let database = CommandLine.arguments.dropFirst().first else { fatalError("Fixture database required") }
precondition(database.contains("/build/opencode-testing/revalidation-ui-home/"))
var connection: OpaquePointer?
precondition(sqlite3_open_v2(database, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
var query: OpaquePointer?
precondition(
    sqlite3_prepare_v2(connection, "SELECT id,directory FROM session_v2 WHERE id='ses_synthetic_root'", -1, &query, nil)
        == SQLITE_OK)
precondition(sqlite3_step(query) == SQLITE_ROW)
let id = String(cString: sqlite3_column_text(query, 0))
let folder = String(cString: sqlite3_column_text(query, 1))
sqlite3_finalize(query)
sqlite3_close(connection)
var lastOwnedChange: Int?
print("READY clipboard snapshot held only in memory; changeCount \(board.changeCount), items \(original.count)")
while let line = readLine() {
    switch line {
    case "id", "folder":
        let expected = line == "id" ? id : folder
        let valid = board.string(forType: .string) == expected
        if valid { lastOwnedChange = board.changeCount }
        print("\(valid ? "PASS" : "FAIL") actual menu clipboard equals fixture \(line) verbatim")
    case "restore":
        if let lastOwnedChange, lastOwnedChange == board.changeCount {
            board.clearContents()
            if !original.isEmpty { board.writeObjects(original) }
            let restored =
                (board.pasteboardItems ?? []).count == original.count
                && zip(board.pasteboardItems ?? [], original).allSatisfy { current, saved in
                    current.types == saved.types
                        && saved.types.allSatisfy { current.data(forType: $0) == saved.data(forType: $0) }
                }
            print("\(restored ? "PASS" : "FAIL") original pasteboard types/data restored without disclosure")
        } else {
            print("DEFERRED pasteboard changed externally; preserved current contents")
        }
        exit(0)
    default: print("Unknown clipboard test command")
    }
}
