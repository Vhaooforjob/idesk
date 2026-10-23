import AppKit
import CoreGraphics

/// What the screens' picture needs from the system: backlight over DDC/CI,
/// a gamma table per screen, and Night Shift. Injectable so the view model
/// can be tested without touching the developer's screens.
@MainActor
protocol ScreenTuningSystem: AnyObject {
    func identifier(for id: CGDirectDisplayID) -> String?
    /// Looks for the DDC channels of these screens. Call after screens are
    /// plugged in or woken.
    func prepareHardware(for ids: [CGDirectDisplayID])
    /// The screen's own backlight, or nil when it does not answer.
    func hardwareBrightness(of id: CGDirectDisplayID) async -> DDCBus.Level?
    func setHardwareBrightness(_ value: Int, of id: CGDirectDisplayID) async -> Bool
    /// Any other DDC/CI feature, such as the color preset.
    func hardwareFeature(_ code: UInt8, of id: CGDirectDisplayID) async -> DDCBus.Level?
    func setHardwareFeature(_ code: UInt8, to value: Int, of id: CGDirectDisplayID) async -> Bool
    /// The features the screen says it has, each with the values it allows.
    /// Slow: it takes a second or more.
    func hardwareCapabilities(of id: CGDirectDisplayID) async -> [UInt8: [UInt8]]?
    func applyGain(_ gain: ScreenColor.Gain, to id: CGDirectDisplayID)
    /// Gives every screen back the colors macOS sends.
    func restoreColors()
    func nightShiftStatus() -> NightShiftStatus?
    func setNightShift(_ on: Bool) -> Bool
    /// Called when Night Shift changes, whoever changed it.
    var onNightShiftChange: (() -> Void)? { get set }
}

@MainActor
final class LiveScreenTuningSystem: ScreenTuningSystem {
    /// DDC commands are slow and must not overlap, so they all run here.
    private let queue = DispatchQueue(label: "dev.idesk.ddc", qos: .userInitiated)
    private let bus = DDCBus()
    private let nightShift = NightShiftBridge()
    private var channels: [CGDirectDisplayID: DDCBus.Channel] = [:]

    func identifier(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    func prepareHardware(for ids: [CGDirectDisplayID]) {
        let all = DDCBus.channels()
        let screens = ids.map { DDCBus.Screen(id: $0, vendor: UInt16(truncatingIfNeeded: CGDisplayVendorNumber($0)),
                                              model: UInt16(truncatingIfNeeded: CGDisplayModelNumber($0))) }
        let matches = DDCBus.match(screens: screens, channels: all.map { ($0.vendor, $0.model) })
        channels = matches.compactMapValues { all.indices.contains($0) ? all[$0] : nil }
    }

    func hardwareBrightness(of id: CGDirectDisplayID) async -> DDCBus.Level? {
        guard let channel = channels[id] else { return nil }
        let bus = bus
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: bus.brightness(of: channel)) }
        }
    }

    func setHardwareBrightness(_ value: Int, of id: CGDirectDisplayID) async -> Bool {
        guard let channel = channels[id] else { return false }
        let bus = bus
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: bus.setBrightness(value, of: channel)) }
        }
    }

    func hardwareFeature(_ code: UInt8, of id: CGDirectDisplayID) async -> DDCBus.Level? {
        guard let channel = channels[id] else { return nil }
        let bus = bus
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: bus.feature(code, of: channel)) }
        }
    }

    func setHardwareFeature(_ code: UInt8, to value: Int, of id: CGDirectDisplayID) async -> Bool {
        guard let channel = channels[id] else { return false }
        let bus = bus
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: bus.setFeature(code, to: value, of: channel)) }
        }
    }

    func hardwareCapabilities(of id: CGDirectDisplayID) async -> [UInt8: [UInt8]]? {
        guard let channel = channels[id] else { return nil }
        let bus = bus
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: bus.capabilities(of: channel).map(DDCBus.features(in:))) }
        }
    }

    func applyGain(_ gain: ScreenColor.Gain, to id: CGDirectDisplayID) {
        CGSetDisplayTransferByFormula(id, 0, CGGammaValue(gain.red), 1, 0, CGGammaValue(gain.green), 1,
                                      0, CGGammaValue(gain.blue), 1)
    }

    func restoreColors() {
        CGDisplayRestoreColorSyncSettings()
    }

    var onNightShiftChange: (() -> Void)? {
        get { nightShift.onChange }
        set { nightShift.onChange = newValue }
    }

    func nightShiftStatus() -> NightShiftStatus? { nightShift.status() }
    func setNightShift(_ on: Bool) -> Bool { nightShift.setEnabled(on) }
}
