import Foundation
import SidelightCore
import SwiftUI

extension OpenRouterProblem {
    var title: String {
        switch self {
        case .noKey: "No management key"
        case .invalidKey: "OpenRouter doesn't accept the key"
        case .notPermitted: "The key may not read this"
        case .notManagementKey: "Not a management key"
        case .keyNotFound: "Key not found"
        case .rateLimited: "OpenRouter asked to wait"
        case .unavailable: "OpenRouter is having trouble"
        case .badRequest: "OpenRouter rejected the request"
        case .unreadable: "Unexpected answer from OpenRouter"
        case .tooLarge: "Unexpectedly large answer"
        case .unreachable: "Can't reach OpenRouter"
        case .keychain: "Can't read the key from the keychain"
        }
    }

    var advice: String {
        switch self {
        case .noKey:
            "Replace the account's key in Settings, under Accounts."
        case .invalidKey:
            "The key may have been deleted or disabled. Replace it with a current management key in Settings, under "
                + "Accounts."
        case .notPermitted:
            "The key's permissions don't cover this. Check the key in OpenRouter, then replace it in Settings, under "
                + "Accounts."
        case .notManagementKey:
            "An inference key can't read the account's balance or spending. Create a management key in OpenRouter."
        case .keyNotFound:
            "The account no longer has the key the chart shows. Choose another in the widget's builder."
        case .rateLimited:
            "Sidelight tries again once OpenRouter allows it."
        case .unavailable(let status):
            "Status \(status). Sidelight tries again in a while."
        case .badRequest(let message):
            message ?? "Asking again won't help; this may need a newer Sidelight."
        case .unreadable:
            "Nothing is shown that it can't vouch for. Sidelight tries again in a while."
        case .tooLarge:
            "The answer was larger than OpenRouter's catalogue ever is, so it wasn't read."
        case .unreachable:
            "Check your connection. Sidelight tries again in a while."
        case .keychain:
            "The keychain may be locked. Sidelight tries again in a while."
        }
    }

    /// How the account is doing, when it's this; `nil` for what isn't about the account (a chart's key that's gone).
    var accountStatus: AccountStatus? {
        switch self {
        case .noKey: .needsSignIn
        case .invalidKey: .expired
        case .keyNotFound: nil
        default: .failed(title)
        }
    }

    /// Fixed only by saving a key again: Sidelight doesn't ask OpenRouter again with a key it rejected.
    var needsKey: Bool {
        switch self {
        case .noKey, .invalidKey, .notPermitted, .notManagementKey: true
        default: false
        }
    }
}

extension OpenRouterModelSort {
    var title: String {
        switch self {
        case .latestAdded: "Latest added"
        case .name: "Name"
        case .context: "Largest context"
        case .inputPrice: "Cheapest input"
        case .outputPrice: "Cheapest output"
        }
    }
}

extension OpenRouterModality {
    /// `Text`, `Embeddings`; a kind OpenRouter added since by its own name.
    var title: String {
        switch self {
        case .text: "Text"
        case .image: "Image"
        case .file: "File"
        case .audio: "Audio"
        case .video: "Video"
        case .speech: "Speech"
        case .decisions: "Decisions"
        case .embeddings: "Embeddings"
        case .rerank: "Rerank"
        case .transcription: "Transcription"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    var systemImage: String {
        switch self {
        case .text: "textformat"
        case .image: "photo"
        case .file: "doc"
        case .audio: "waveform"
        case .video: "video"
        case .speech: "person.wave.2"
        case .decisions: "arrow.triangle.branch"
        case .embeddings: "point.3.connected.trianglepath.dotted"
        case .rerank: "arrow.up.arrow.down"
        case .transcription: "mic"
        default: "square.dashed"
        }
    }
}

extension OpenRouterModelFilter {
    /// `All`, `Text`, `Text-only`, `Image · reads image, file`.
    var title: String {
        if self == .textOnly { return "Text-only" }
        let output = output?.title ?? "All"
        guard !inputs.isEmpty else { return isExact && self.output != nil ? "\(output) only" : output }
        return "\(output) · reads \(inputList)\(isExact ? " only" : "")"
    }

    /// `image, file`
    var inputList: String {
        OpenRouterModality.ordered(inputs, as: OpenRouterModality.knownInputs).map { $0.title.lowercased() }
            .joined(separator: ", ")
    }

    var explanation: String {
        if isAll { return "Every model, including embeddings, speech, images and video." }
        if self == .textOnly { return "Text in, text out, nothing else." }
        var parts: [String] = []
        if let output {
            parts.append(isExact ? "Produce only \(output.title.lowercased())" : "Produce \(output.title.lowercased())")
        }
        if !inputs.isEmpty {
            parts.append(isExact ? "read only \(inputList)" : "read \(inputList), among others")
        }
        let sentence = parts.joined(separator: " and ")
        return "Models that " + sentence.prefix(1).lowercased() + sentence.dropFirst() + "."
    }

    /// `662 models`, `459 text models`, `12 models · Image · reads file`.
    func count(_ count: Int) -> String {
        let noun = count == 1 ? "model" : "models"
        if isAll { return "\(count) \(noun)" }
        if inputs.isEmpty || self == .textOnly { return "\(count) \(title.lowercased()) \(noun)" }
        return "\(count) \(noun) · \(title)"
    }
}

extension OpenRouterRowDensity {
    var title: String {
        switch self {
        case .lean: "Lean"
        case .standard: "Standard"
        case .detail: "Detail"
        }
    }
}

extension OpenRouterGlance {
    var title: String {
        switch self {
        case .automatic: "The first block's"
        case .newest: "Newest model"
        case .count: "Number of models"
        case .balance: "Balance"
        }
    }
}

extension OpenRouterPreset {
    var title: String {
        switch self {
        case .latest: "Latest models"
        case .overview: "Overview"
        case .credits: "Credits"
        case .textOnly: "Text-only"
        case .richList: "Rich list"
        }
    }
}

/// How OpenRouter's numbers read in Sidelight.
enum OpenRouterFormat {
    /// `$74.25`, `-$1.20`.
    static func dollars(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// A day's spending: like ``dollars(_:)``, but `<$0.01` for less than a cent, so a tiny day doesn't read as
    /// nothing.
    static func dayAmount(_ value: Decimal) -> String {
        value > 0 && value < cent ? "<$0.01" : dollars(value)
    }

    private static let cent = Decimal(sign: .plus, exponent: -2, significand: 1)

    /// A price per million tokens: `$4`, `$2.70`, `$0.0025`, `Varies`, or `—` when unknown. Never "free".
    static func pricePerMillion(_ price: OpenRouterTokenPrice) -> String {
        switch price {
        case .varies: return "Varies"
        case .unknown: return "—"
        case .perToken:
            guard let value = price.perMillion else { return "—" }
            if value == value.roundedToWhole {
                return "$" + value.formatted(.number.precision(.fractionLength(0)))
            }
            if value >= cent {
                return "$" + value.formatted(.number.precision(.fractionLength(2)))
            }
            return "$" + value.formatted(.number.precision(.significantDigits(1...3)))
        }
    }

    /// `$1 / $2.70 per M`
    static func prices(of model: OpenRouterModel) -> String {
        "\(pricePerMillion(model.inputPrice)) / \(pricePerMillion(model.outputPrice))"
    }

    /// `1M`, `262K`, `8192` tokens.
    static func context(_ tokens: Int) -> String {
        let millions = Double(tokens) / 1_000_000
        if millions >= 1 {
            let rounded = millions.rounded()
            return abs(millions - rounded) < 0.06 ? "\(Int(rounded))M" : String(format: "%.1fM", millions)
        }
        return tokens >= 1000 ? "\(Int((Double(tokens) / 1000).rounded()))K" : "\(tokens)"
    }

    /// `text·image·file → text`
    static func modalities(of model: OpenRouterModel) -> String {
        let inputs = model.inputModalities.isEmpty ? "?" : model.inputModalities.joined(separator: "·")
        let outputs = model.outputModalities.isEmpty ? "?" : model.outputModalities.joined(separator: "·")
        return "\(inputs) → \(outputs)"
    }

    /// `Oct 31`, for a day in UTC.
    static func day(_ day: UTCDay) -> String {
        day.start.formatted(Date.FormatStyle(timeZone: .gmt).month(.abbreviated).day())
    }

    /// `Oct 31, 2026`, for a day in UTC.
    static func longDay(_ day: UTCDay) -> String {
        day.start.formatted(Date.FormatStyle(timeZone: .gmt).month(.abbreviated).day().year())
    }
}

extension Decimal {
    /// Rounded to a whole number, half up.
    fileprivate var roundedToWhole: Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, 0, .plain)
        return result
    }

    /// As a `Double`, for drawing: never for arithmetic on money.
    var approximateDouble: Double { (self as NSDecimalNumber).doubleValue }
}

/// A tiny refresh button that turns into a spinner while a fetch is under way, and only then: nothing animates the
/// rest of the time. A 22-point target, whatever the icon's size.
struct OpenRouterRefreshButton: View {
    let isFetching: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Group {
            if isFetching {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Refreshing")
            } else {
                Button(action: action) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(help)
                .accessibilityLabel("Refresh")
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// A small capsule label on a model: `Free`, `Retiring Oct 31`, `Varies`.
struct OpenRouterBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}
