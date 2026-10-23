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
    func applyGain(_ gain: ScreenColor.Gain, to id: CGDirectDisplayID)
    /// Gives every screen back the colors macOS sends.
    func restoreColors()
    func nightShiftStatus() -> NightShiftStatus?
    func setNightShift(_ on: Bool) -> Bool
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

    func applyGain(_ gain: ScreenColor.Gain, to id: CGDirectDisplayID) {
        CGSetDisplayTransferByFormula(id, 0, CGGammaValue(gain.red), 1, 0, CGGammaValue(gain.green), 1,
                                      0, CGGammaValue(gain.blue), 1)
    }

    func restoreColors() {
        CGDisplayRestoreColorSyncSettings()
    }

    func nightShiftStatus() -> NightShiftStatus? { nightShift.status() }
    func setNightShift(_ on: Bool) -> Bool { nightShift.setEnabled(on) }
}
