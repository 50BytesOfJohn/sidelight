import Foundation

/// What one Codex session's rollout file (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) says about the session
/// now: whether a turn is running, what it waits for, its plan, how full its context is.
///
/// Codex appends an event to the file as each thing happens: `task_started` and `task_complete` (or
/// `turn_aborted`) around every turn, each tool call and later its output, `token_count` after every model
/// response. Approval prompts aren't logged, but a call asking for escalated permissions stays without an output
/// until it's approved and has run. The format is undocumented (checked against Codex 0.162), so it's read
/// leniently: a line that doesn't decode is skipped.
public struct CodexRolloutState: Equatable, Sendable {
    public enum Turn: Equatable, Sendable {
        case running(since: Date)
        case completed(at: Date)
        /// Interrupted by the user, or stopped by an error.
        case aborted(at: Date)
    }

    /// A tool call still waiting for its output that may be waiting for the user.
    public struct PendingCall: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A command that asks to run outside the sandbox, which needs an approval unless the approval policy
            /// or Codex's reviewer allows it. `command` is the shell command, when the call says it plainly.
            case escalation(justification: String?, command: String?)
            /// A question for the user.
            case question
        }

        public var kind: Kind
        public var calledAt: Date

        public init(kind: Kind, calledAt: Date) {
            self.kind = kind
            self.calledAt = calledAt
        }
    }

    /// From the file's first line.
    public var meta: CodexSessionMeta?
    public var turn: Turn?
    /// ``turn`` is a guess from activity seen without the turn's start, which came before what was read.
    var turnIsInferred = false
    /// Calls that may wait for the user, by call ID, in the current turn.
    public var pendingCalls: [String: PendingCall] = [:]
    /// The plan's steps as last updated, and whether that was in the current (or last) turn.
    public var plan: [CodexPlanStep] = []
    public var planIsCurrent = false
    /// Files the current (or last) turn changed.
    public var changedFiles: Set<String> = []
    /// The agent's latest message, on one line.
    public var lastMessage: String?
    /// How long the last finished turn took.
    public var lastTurnDuration: TimeInterval?
    public var context: CodexContextUsage?
    public var rateLimits: CodexRateLimits?
    public var rateLimitsCapturedAt: Date?

    public init() {}

    /// The oldest pending call, which is what the session waits on first.
    public var firstPendingCall: PendingCall? {
        pendingCalls.values.min { $0.calledAt < $1.calledAt }
    }
}

/// The first line of a rollout file: who started the session and, for a subagent, whose it is.
public struct CodexSessionMeta: Equatable, Sendable {
    /// The client that started it: `codex-tui`, `Codex Desktop`, `codex_vscode`, `codex_exec`, …
    public var originator: String?
    /// The session this one works for, for subagents such as Codex's approval reviewer.
    public var parentThreadID: String?
    /// Codex's automatic approval reviewer ("guardian").
    public var isApprovalReviewer: Bool

    public init(originator: String? = nil, parentThreadID: String? = nil, isApprovalReviewer: Bool = false) {
        self.originator = originator
        self.parentThreadID = parentThreadID
        self.isApprovalReviewer = isApprovalReviewer
    }
}

public struct CodexPlanStep: Hashable, Sendable {
    public enum Status: String, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var text: String
    public var status: Status

    public init(_ text: String, _ status: Status) {
        self.text = text
        self.status = status
    }
}

/// How full a session's context window is, after its latest model response.
public struct CodexContextUsage: Hashable, Sendable {
    /// Codex leaves this much of every window out of its own percentage: the system prompt and tools are always
    /// there.
    static let baselineTokens = 12_000

    public var tokens: Int
    public var window: Int

    public init(tokens: Int, window: Int) {
        self.tokens = tokens
        self.window = window
    }

    /// What's left of the window, 0–100, worked out as Codex's own "% context left" is.
    public var percentLeft: Double {
        guard window > Self.baselineTokens else { return 0 }
        let effective = Double(window - Self.baselineTokens)
        let used = Double(max(tokens - Self.baselineTokens, 0))
        return min(max((effective - used) / effective * 100, 0), 100)
    }
}

/// Follows one rollout file as Codex appends to it: the first read takes the end of the file, later reads only
/// what was added since.
public struct CodexRolloutFollower: Sendable {
    /// How much of the end of the file the first read takes. A turn's start is usually in it; when it isn't, the
    /// last turn event is looked for further back, up to ``turnRecoveryLimit``.
    public static let initialTailSize = 512 * 1024
    static let turnRecoveryLimit: UInt64 = 8 * 1024 * 1024
    /// The first line, with the session's details, is read once, up to this much.
    static let headSize = 128 * 1024

    public private(set) var state = CodexRolloutState()
    private var offset: UInt64 = 0
    private var fileNumber: UInt64?
    private var partialLine = Data()
    private var hasReadHead = false
    /// How many bytes the last read took from the file, for tests.
    private(set) var lastReadByteCount = 0

    public init() {}

    /// Reads what was added to `url` since the last read. Starts over if the file was replaced or truncated.
    public mutating func read(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let number = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        guard let size = try? handle.seekToEnd() else { return }
        if number != fileNumber || size < offset {
            self = CodexRolloutFollower()
            fileNumber = number
        }
        if !hasReadHead {
            hasReadHead = true
            try? handle.seek(toOffset: 0)
            if let head = try? handle.read(upToCount: Self.headSize),
                let firstLine = head.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false).first
            {
                state.meta = CodexRolloutReducer.meta(in: Data(firstLine))
            }
        }
        lastReadByteCount = 0
        guard size > offset else { return }
        var start = offset
        var skipsFirstLine = false
        if offset == 0, size > UInt64(Self.initialTailSize) {
            start = size - UInt64(Self.initialTailSize)
            skipsFirstLine = true
        }
        try? handle.seek(toOffset: start)
        guard var data = try? handle.read(upToCount: Int(size - start)) else { return }
        offset = start + UInt64(data.count)
        lastReadByteCount = data.count
        var cutLine = Data()
        if skipsFirstLine, let newline = data.firstIndex(of: 0x0A) {
            cutLine = Data(data[..<newline])
            data = data[data.index(after: newline)...]
        }
        consume(Data(data))
        if skipsFirstLine, state.turn == nil || state.turnIsInferred,
            let event = Self.lastTurnEvent(in: handle, before: start, endingWith: cutLine)
        {
            var recovered = CodexRolloutState()
            CodexRolloutReducer.apply(event, to: &recovered)
            // A turn still running since before the tail; a finished one only when the tail says nothing.
            if case .running = recovered.turn {
                state.turn = recovered.turn
                state.turnIsInferred = false
            } else if state.turn == nil {
                state.turn = recovered.turn
            }
        }
    }

    /// The last turn start or end before `end`, reading back a chunk at a time up to ``turnRecoveryLimit``.
    /// `cutLine` is the start of the line that runs past `end`.
    private static func lastTurnEvent(in handle: FileHandle, before end: UInt64, endingWith cutLine: Data) -> Data? {
        let lowest = end > turnRecoveryLimit ? end - turnRecoveryLimit : 0
        let chunkSize = UInt64(initialTailSize)
        var chunkEnd = end
        // The start of a line whose rest came after the chunk read last.
        var carried = cutLine
        while chunkEnd > lowest {
            let chunkStart = max(lowest, chunkEnd > chunkSize ? chunkEnd - chunkSize : 0)
            try? handle.seek(toOffset: chunkStart)
            guard var data = try? handle.read(upToCount: Int(chunkEnd - chunkStart)) else { return nil }
            data.append(carried)
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            if chunkStart > 0, !lines.isEmpty { carried = Data(lines.removeFirst()) }
            if let event = lines.last(where: CodexRolloutReducer.isTurnEvent) { return Data(event) }
            chunkEnd = chunkStart
        }
        return nil
    }

    /// Takes appended bytes; a line without its newline yet waits for the next read.
    public mutating func consume(_ data: Data) {
        var buffer = partialLine
        buffer.append(data)
        guard let lastNewline = buffer.lastIndex(of: 0x0A) else {
            partialLine = buffer
            return
        }
        partialLine = Data(buffer[buffer.index(after: lastNewline)...])
        for line in buffer[..<lastNewline].split(separator: 0x0A) {
            CodexRolloutReducer.apply(Data(line), to: &state)
        }
    }
}

/// Turns rollout lines into ``CodexRolloutState`` changes. Only lines with one of a few markers are decoded; the
/// rest are messages and tool output, often large.
enum CodexRolloutReducer {
    private static let markers: [(Data, Kind)] = [
        (Data(#""type":"task_started""#.utf8), .turnStarted),
        (Data(#""type":"task_complete""#.utf8), .turnCompleted),
        (Data(#""type":"turn_aborted""#.utf8), .turnAborted),
        // The names Codex's protocol also accepts for a turn's start and end.
        (Data(#""type":"turn_started""#.utf8), .turnStarted),
        (Data(#""type":"turn_complete""#.utf8), .turnCompleted),
        (Data(#""type":"token_count""#.utf8), .tokenCount),
        (Data(#""type":"function_call_output""#.utf8), .callOutput),
        (Data(#""type":"custom_tool_call_output""#.utf8), .callOutput),
        (Data(#""type":"function_call""#.utf8), .call),
        (Data(#""type":"custom_tool_call""#.utf8), .call),
        (Data(#""item":{"type":"AgentMessage""#.utf8), .agentMessage),
        (Data(#""type":"agent_message""#.utf8), .agentMessage),
        (Data(#""item":{"type":"FileChange""#.utf8), .fileChange),
    ]

    private enum Kind {
        case turnStarted, turnCompleted, turnAborted, tokenCount, call, callOutput, agentMessage, fileChange
    }

    /// Where a line says what it is: `{"timestamp":…,"type":"response_item","payload":{"type":"…"`. Markers further
    /// in are inside its content.
    private static let headerLength = 320

    /// Whether the line starts or ends a turn.
    static func isTurnEvent(_ line: Data) -> Bool {
        let header = line.prefix(headerLength)
        return markers.prefix(5).contains { header.firstRange(of: $0.0) != nil }
    }

    static func apply(_ line: Data, to state: inout CodexRolloutState) {
        let header = line.prefix(headerLength)
        guard let kind = markers.first(where: { header.firstRange(of: $0.0) != nil })?.1 else { return }

        if kind == .callOutput {
            // Tool output can be megabytes; its call ID comes before it.
            if let callID = callID(in: header) { state.pendingCalls[callID] = nil }
            return
        }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: line) else { return }
        let date = entry.timestamp ?? .now
        let payload = entry.payload

        switch kind {
        case .turnStarted:
            state.turn = .running(since: date)
            state.turnIsInferred = false
            state.pendingCalls = [:]
            state.changedFiles = []
            state.planIsCurrent = false
        case .turnCompleted:
            state.turn = .completed(at: date)
            state.turnIsInferred = false
            state.pendingCalls = [:]
            if let message = payload.lastAgentMessage.flatMap(oneLine) { state.lastMessage = message }
            state.lastTurnDuration = payload.durationMilliseconds.map { Double($0) / 1000 }
        case .turnAborted:
            state.turn = .aborted(at: date)
            state.turnIsInferred = false
            state.pendingCalls = [:]
        case .tokenCount:
            if let context = payload.context { state.context = context }
            if let rateLimits = payload.rateLimits {
                state.rateLimits = rateLimits
                state.rateLimitsCapturedAt = date
            }
        case .call:
            if state.turn == nil {
                state.turn = .running(since: date)
                state.turnIsInferred = true
            }
            guard let callID = payload.callID else { return }
            let text = payload.callText ?? ""
            if let steps = planSteps(in: text, name: payload.name), !steps.isEmpty {
                state.plan = steps
                state.planIsCurrent = true
            }
            if let kind = pendingKind(name: payload.name, text: text) {
                state.pendingCalls[callID] = .init(kind: kind, calledAt: date)
            }
        case .agentMessage:
            if let message = payload.message.flatMap(oneLine) { state.lastMessage = message }
        case .fileChange:
            state.changedFiles.formUnion(payload.changedPaths)
        case .callOutput:
            break
        }
    }

    static func meta(in line: Data) -> CodexSessionMeta? {
        guard let entry = try? JSONDecoder().decode(MetaEntry.self, from: line), entry.type == "session_meta" else {
            return nil
        }
        return entry.meta
    }

    // MARK: Tool calls

    /// Whether a call may wait for the user: a command asking for escalated permissions, or a question.
    static func pendingKind(name: String?, text: String) -> CodexRolloutState.PendingCall.Kind? {
        if name == "request_user_input" || text.contains("tools.request_user_input(") { return .question }
        guard
            text.contains("require_escalated") || text.contains(#"with_escalated_permissions":true"#)
                || text.contains("with_escalated_permissions:true")
        else { return nil }
        return .escalation(
            justification: stringValue(of: "justification", in: text).flatMap(oneLine),
            command: stringValue(of: "cmd", in: text))
    }

    /// The steps of an `update_plan` call: JSON arguments, or the `plan` passed to it in a code-mode script, which
    /// may call it as `tools.update_plan(…)` or look it up by name first.
    static func planSteps(in text: String, name: String?) -> [CodexPlanStep]? {
        guard name == "update_plan" || text.contains("update_plan"),
            let start = text.firstRange(of: planStartPattern)
        else { return nil }
        let source = text[start.upperBound...]
        var steps: [CodexPlanStep] = []
        for match in source.matches(of: planStepPattern) {
            guard let status = CodexPlanStep.Status(rawValue: String(match.output.2)),
                let step = unescaped(match.output.1).flatMap(oneLine)
            else { continue }
            steps.append(CodexPlanStep(step, status))
            // A script may call it again; the first plan in it is enough.
            if source[match.range.upperBound...].hasPrefix("]") { break }
        }
        return steps
    }

    private nonisolated(unsafe) static let planStartPattern = /"?plan"?\s*:\s*\[/
    private nonisolated(unsafe) static let planStepPattern =
        /"?step"?\s*:\s*"((?:[^"\\]|\\.)*)"\s*,\s*"?status"?\s*:\s*"(\w+)"\s*\}/

    /// A string field in JSON or a JavaScript object literal, unescaped.
    static func stringValue(of key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "\(key)\"?\\s*:\\s*\"", options: .regularExpression) else { return nil }
        var escaped = false
        var end = keyRange.upperBound
        while end < text.endIndex {
            let character = text[end]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return unescaped(text[keyRange.upperBound..<end])
            }
            end = text.index(after: end)
        }
        return nil
    }

    private static func unescaped(_ text: Substring) -> String? {
        (try? JSONDecoder().decode(String.self, from: Data("\"\(text)\"".utf8))) ?? String(text)
    }

    private static func callID(in header: Data) -> String? {
        let marker = Data(#""call_id":""#.utf8)
        guard let range = header.firstRange(of: marker),
            let end = header[range.upperBound...].firstIndex(of: UInt8(ascii: "\""))
        else { return nil }
        return String(decoding: header[range.upperBound..<end], as: UTF8.self)
    }

    /// Runs of whitespace and line breaks as single spaces; `nil` when nothing's left. Long text is cut, since only
    /// its start is ever shown.
    static func oneLine(_ text: String) -> String? {
        let words = text.prefix(600).split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    // MARK: Wire format

    private struct Entry: Decodable {
        var timestamp: Date?
        var payload: Payload

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            payload = try container.decode(Payload.self, forKey: AnyCodingKey("payload"))
            timestamp = container.lenient(String.self, "timestamp").flatMap(Date.init(iso8601:))
        }
    }

    private struct Payload: Decodable {
        var name: String?
        var callID: String?
        /// A function call's arguments, or a custom tool call's input.
        var callText: String?
        var message: String?
        var lastAgentMessage: String?
        var durationMilliseconds: Int64?
        var context: CodexContextUsage?
        var rateLimits: CodexRateLimits?
        var changedPaths: [String] = []

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            name = container.lenient(String.self, "name")
            callID = container.lenient(String.self, "call_id")
            callText = container.lenient(String.self, "arguments", "input")
            lastAgentMessage = container.lenient(String.self, "last_agent_message")
            durationMilliseconds = container.lenientInt64("duration_ms")
            rateLimits = container.lenient(CodexRateLimits.self, "rate_limits")
            if let info = container.lenient(TokenInfo.self, "info"), let tokens = info.tokens, let window = info.window,
                window > 0
            {
                context = CodexContextUsage(tokens: tokens, window: window)
            }
            if let item = container.lenient(Item.self, "item") {
                message = item.text
                changedPaths = item.changedPaths
            } else {
                message = container.lenient(String.self, "message")
            }
        }
    }

    private struct TokenInfo: Decodable {
        var tokens: Int?
        var window: Int?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            window = container.lenientInt64("model_context_window").map(Int.init)
            tokens = container.lenient(Usage.self, "last_token_usage")?.total
        }

        struct Usage: Decodable {
            var total: Int?

            init(from decoder: any Decoder) throws {
                total = try decoder.container(keyedBy: AnyCodingKey.self).lenientInt64("total_tokens").map(Int.init)
            }
        }
    }

    private struct Item: Decodable {
        var text: String?
        var changedPaths: [String] = []

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            let parts = container.lenient([Part].self, "content") ?? []
            let text = parts.compactMap(\.text).joined(separator: "\n")
            self.text = text.isEmpty ? nil : text
            if let changes = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("changes"))
            {
                changedPaths = changes.allKeys.map(\.stringValue)
            }
        }

        struct Part: Decodable {
            var text: String?

            init(from decoder: any Decoder) throws {
                text = try decoder.container(keyedBy: AnyCodingKey.self).lenient(String.self, "text")
            }
        }
    }

    private struct MetaEntry: Decodable {
        var type: String?
        var meta: CodexSessionMeta

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            type = container.lenient(String.self, "type")
            let payload = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("payload"))
            let source = payload.lenient(SourceInfo.self, "source")
            meta = CodexSessionMeta(
                originator: payload.lenient(String.self, "originator"),
                parentThreadID: payload.lenient(String.self, "parent_thread_id") ?? source?.parentThreadID,
                isApprovalReviewer: payload.lenient(String.self, "thread_source") == "guardian_review"
                    || source?.isGuardian == true
            )
        }
    }

    /// `"cli"`, or `{"subagent": {"other": "guardian"}}`, or `{"subagent": {"thread_spawn": {"parent_thread_id": …}}}`.
    private struct SourceInfo: Decodable {
        var parentThreadID: String?
        var isGuardian = false

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            let subagent = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("subagent"))
            isGuardian = subagent?.lenient(String.self, "other") == "guardian"
            let spawn = try? subagent?.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("thread_spawn"))
            parentThreadID = spawn?.lenient(String.self, "parent_thread_id")
        }
    }
}
