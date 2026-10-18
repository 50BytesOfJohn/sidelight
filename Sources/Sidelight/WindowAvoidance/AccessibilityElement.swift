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

    /// Moves the window. Position and size are separate Accessibility writes, with the window composited in between,
    /// so which one goes first decides what's briefly on screen: ``WindowPlacer`` owns that order, and nothing here
    /// writes both.
    func setPosition(_ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
    }

    func setSize(_ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }

    /// Whether the app's enhanced user interface is on: VoiceOver and some window tools turn it on, and then the app
    /// animates frame changes and can drop part of one. ``WindowPlacer`` turns it off for a whole placement, so a
    /// window that takes several writes to settle animates none of them.
    var hasEnhancedUserInterface: Bool {
        attribute(Self.enhancedUserInterfaceAttribute) ?? false
    }

    func setEnhancedUserInterface(_ isOn: Bool) {
        setAttribute(Self.enhancedUserInterfaceAttribute, to: isOn)
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
    /// `AXEnhancedUserInterface` is left alone, as it makes apps animate window changes (see ``hasEnhancedUserInterface``).
    /// Electron answers `attributeUnsupported` even when it takes the request, so there's no telling whether it did.
    func requestAccessibilityTree() {
        setAttribute(Self.manualAccessibilityAttribute, to: true)
    }

    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    private static let manualAccessibilityAttribute = "AXManualAccessibility"

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
