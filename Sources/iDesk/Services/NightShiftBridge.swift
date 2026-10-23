import Foundation

/// Reads and flips macOS Night Shift. There is no public API: this uses
/// the private `CBBlueLightClient` of CoreBrightness, looked up at runtime.
/// If macOS removes it, `status()` returns nil and the switch is hidden.
///
/// Night Shift is one setting for the whole Mac, not per screen.
final class NightShiftBridge {
    private typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Bool

    private static let getSelector = Selector(("getBlueLightStatus:"))
    private static let setSelector = Selector(("setEnabled:"))
    /// The status struct is read by offset, so its layout can be checked in
    /// one place: BOOL active, BOOL enabled, BOOL sunSchedulePermitted,
    /// int mode, schedule, flags, BOOL available.
    private static let statusSize = 64
    private static let enabledOffset = 1
    private static let availableOffset = 32

    private typealias SetNotification = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private static let notificationSelector = Selector(("setStatusNotificationBlock:"))

    private let client: NSObject?
    private var notification: (@convention(block) () -> Void)?
    /// Called on the main queue when Night Shift turns on or off, from
    /// System Settings, Control Center, its schedule or iDesk.
    var onChange: (() -> Void)? {
        didSet { listen() }
    }

    init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type
        let candidate = type?.init()
        client = candidate?.responds(to: Self.getSelector) == true && candidate?.responds(to: Self.setSelector) == true
            ? candidate : nil
    }

    private func listen() {
        guard let client, client.responds(to: Self.notificationSelector) else { return }
        let set = unsafeBitCast(client.method(for: Self.notificationSelector), to: SetNotification.self)
        let block: @convention(block) () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.onChange?() }
        }
        notification = block
        set(client, Self.notificationSelector, unsafeBitCast(block, to: AnyObject.self))
    }

    func status() -> NightShiftStatus? {
        guard let client else { return nil }
        let get = unsafeBitCast(client.method(for: Self.getSelector), to: GetStatus.self)
        var buffer = [UInt8](repeating: 0, count: Self.statusSize)
        let ok = buffer.withUnsafeMutableBytes { get(client, Self.getSelector, $0.baseAddress!) }
        guard ok, buffer[Self.availableOffset] != 0 else { return nil }
        return NightShiftStatus(isOn: buffer[Self.enabledOffset] != 0)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard let client else { return false }
        let set = unsafeBitCast(client.method(for: Self.setSelector), to: SetEnabled.self)
        return set(client, Self.setSelector, enabled)
    }
}
