import ApplicationServices
import CoreGraphics

/// A typed view of an `AXUIElement` (an app or one of its windows).
struct AccessibilityElement {
    let element: AXUIElement

    static func application(_ processIdentifier: pid_t) -> AccessibilityElement {
        AccessibilityElement(element: AXUIElementCreateApplication(processIdentifier))
    }

    var processIdentifier: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    var windows: [AccessibilityElement] {
        (attribute(kAXWindowsAttribute) as [AXUIElement]?)?.map(AccessibilityElement.init) ?? []
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

    /// Moves, then resizes. Some apps clamp the origin while the old size still overflows the screen, so the
    /// position is re-applied if it drifted.
    func setFrame(_ frame: CGRect) {
        setPosition(frame.origin)
        setSize(frame.size)
        if let actual = self.frame, abs(actual.minX - frame.minX) > 1 || abs(actual.minY - frame.minY) > 1 {
            setPosition(frame.origin)
        }
    }

    func isSameElement(as other: AccessibilityElement) -> Bool {
        CFEqual(element, other.element)
    }

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

    private func attribute<Value>(_ name: String) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Value
    }
}
