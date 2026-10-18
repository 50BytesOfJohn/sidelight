import ApplicationServices
import CoreGraphics

/// A typed view of an `AXUIElement` (an app or one of its windows).
struct AccessibilityElement {
    /// How long any Accessibility call may wait for an app to answer. Every call blocks the main thread, and the
    /// system's default is six seconds, so a busy or hung app could freeze the panels; apps normally answer within
    /// milliseconds, and one that doesn't is checked again on its next event.
    static let messagingTimeout: Float = 1

    let element: AXUIElement

    static func application(_ processIdentifier: pid_t) -> AccessibilityElement {
        AccessibilityElement(element: AXUIElementCreateApplication(processIdentifier))
    }

    /// Caps how long every Accessibility call of this process waits for an answer (see ``messagingTimeout``).
    static func limitMessagingTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    var processIdentifier: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    var windows: [AccessibilityElement] {
        readableWindows ?? []
    }

    /// The app's windows, or `nil` when they can't be read: unlike ``windows``, an app whose list failed isn't taken
    /// for one without windows.
    var readableWindows: [AccessibilityElement]? {
        (attribute(kAXWindowsAttribute) as [AXUIElement]?)?.map(AccessibilityElement.init)
    }

    /// Regular document/app windows, as opposed to panels, sheets, popovers and the like.
    var isStandardWindow: Bool {
        (attribute(kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
    }

    var isFullScreen: Bool { attribute("AXFullScreen") ?? false }
    var isMinimized: Bool { attribute(kAXMinimizedAttribute) ?? false }
    var title: String { attribute(kAXTitleAttribute) ?? "" }

    /// In Accessibility coordinates (top-left origin).
    var frame: CGRect? {
        guard let positionValue: AXValue = attribute(kAXPositionAttribute),
            let sizeValue: AXValue = attribute(kAXSizeAttribute)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// The app's window with keyboard focus (this element is its application element), falling back to its main
    /// window, or why neither can be read. An app that didn't answer in time (`cannotComplete`) isn't asked again.
    var focusedWindow: Result<AccessibilityElement, AccessibilityReadError> {
        let focused = (read(kAXFocusedWindowAttribute) as Result<AXUIElement, AccessibilityReadError>)
        if case .failure(.failed(.cannotComplete)) = focused { return focused.map(AccessibilityElement.init) }
        guard case .failure = focused else { return focused.map(AccessibilityElement.init) }
        return (read(kAXMainWindowAttribute) as Result<AXUIElement, AccessibilityReadError>)
            .map(AccessibilityElement.init)
    }

    /// Whether the app lets its window be moved.
    var isPositionSettable: Bool { isSettable(kAXPositionAttribute) }
    /// Whether the app lets its window be resized: not for a window of a fixed size.
    var isSizeSettable: Bool { isSettable(kAXSizeAttribute) }

    /// Resizes, moves, then fixes whatever didn't take. Shrinking first means a window never has to cross the
    /// screen's edge on its way; an app that clamped the size while the window still stood in its old place gets it
    /// again once it's moved, and one that clamped the origin while the old size still overflowed gets that again.
    ///
    /// While the app's enhanced user interface is on (VoiceOver, and some window tools, turn it on), apps animate
    /// frame changes and can drop part of one, so it's off for the move and back on after.
    ///
    /// Returns the frame the app accepted, which an app with a minimum or fixed size makes differ; `nil` once the
    /// window can't be read.
    @discardableResult
    func setFrame(_ frame: CGRect) -> CGRect? {
        let application = processIdentifier.map(Self.application)
        let enhancedInterface = application?.attribute(Self.enhancedUserInterfaceAttribute) as Bool? ?? false
        if enhancedInterface { application?.setAttribute(Self.enhancedUserInterfaceAttribute, to: false) }
        defer { if enhancedInterface { application?.setAttribute(Self.enhancedUserInterfaceAttribute, to: true) } }

        setSize(frame.size)
        setPosition(frame.origin)
        guard var actual = self.frame else { return nil }
        if abs(actual.width - frame.width) > 1 || abs(actual.height - frame.height) > 1 {
            setSize(frame.size)
            actual = self.frame ?? actual
        }
        if abs(actual.minX - frame.minX) > 1 || abs(actual.minY - frame.minY) > 1 {
            setPosition(frame.origin)
            actual = self.frame ?? actual
        }
        return actual
    }

    /// The app's element that has keyboard focus (a text field, a text view, a web area), or why it can't be read.
    var focusedElement: Result<AccessibilityElement, AccessibilityReadError> {
        (read(kAXFocusedUIElementAttribute) as Result<AXUIElement, AccessibilityReadError>)
            .map(AccessibilityElement.init)
    }

    var role: String? { attribute(kAXRoleAttribute) }
    var subrole: String? { attribute(kAXSubroleAttribute) }

    /// A password field, whose text must never be read.
    var isSecureTextField: Bool { subrole == kAXSecureTextFieldSubrole }

    /// The text selected in it, or why it can't be read: many apps don't expose their selection.
    var selectedText: Result<String, AccessibilityReadError> { read(kAXSelectedTextAttribute) }

    func isSameElement(as other: AccessibilityElement) -> Bool {
        CFEqual(element, other.element)
    }

    /// Asks an app (this element is its application element) to build its accessibility tree, which Electron apps
    /// leave out until a screen reader seems to need it, and keep it until it quits; a cost in that app, so ask only
    /// for an app that needs it. `AXManualAccessibility` is Electron's switch for exactly this; the broader
    /// `AXEnhancedUserInterface` is left alone, as it makes apps animate window changes (see ``setFrame(_:)``).
    /// Electron answers `attributeUnsupported` even when it takes the request, so there's no telling whether it did.
    func requestAccessibilityTree() {
        setAttribute(Self.manualAccessibilityAttribute, to: true)
    }

    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    private static let manualAccessibilityAttribute = "AXManualAccessibility"

    private func setPosition(_ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
    }

    private func setSize(_ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }

    private func setAttribute(_ name: String, to value: Bool) {
        AXUIElementSetAttributeValue(element, name as CFString, value as CFBoolean)
    }

    private func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private func attribute<Value>(_ name: String) -> Value? {
        try? read(name).get()
    }

    private func read<Value>(_ name: String) -> Result<Value, AccessibilityReadError> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else { return .failure(.failed(error)) }
        guard let value = value as? Value else { return .failure(.unexpectedType) }
        return .success(value)
    }
}

/// Why an attribute couldn't be read, for the log.
enum AccessibilityReadError: Error, CustomStringConvertible {
    /// What Accessibility said: `noValue` for nothing there, `attributeUnsupported` for an app that doesn't offer it,
    /// `cannotComplete` for one that didn't answer in time, `apiDisabled` without access.
    case failed(AXError)
    case unexpectedType

    var description: String {
        switch self {
        case .failed(let error): "AXError \(error.rawValue)"
        case .unexpectedType: "an unexpected type"
        }
    }
}
