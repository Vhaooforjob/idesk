import CoreGraphics
import Foundation
import IOKit

/// DDC/CI: the commands every external screen understands, here for the
/// backlight level. On Apple Silicon a screen's I2C channel is only
/// reachable through the private IOAVService calls, found at runtime. When
/// macOS drops them, or a screen or cable does not pass DDC through, every
/// call fails and the caller falls back to dimming in software.
///
/// Not thread safe: use one instance from one queue.
final class DDCBus: @unchecked Sendable {
    /// One external screen's channel, with the vendor and model its EDID
    /// reports so it can be matched to a display.
    struct Channel: @unchecked Sendable {
        let vendor: UInt16
        let model: UInt16
        fileprivate let service: CFTypeRef
    }

    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private static let symbols: (create: Create, write: Transfer, read: Transfer)? = {
        let handle = dlopen(nil, RTLD_NOW)
        guard let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let write = dlsym(handle, "IOAVServiceWriteI2C"),
              let read = dlsym(handle, "IOAVServiceReadI2C") else { return nil }
        return (unsafeBitCast(create, to: Create.self), unsafeBitCast(write, to: Transfer.self),
                unsafeBitCast(read, to: Transfer.self))
    }()

    private static let brightnessCode: UInt8 = 0x10
    private static let chip: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51
    /// DDC/CI wants a pause between commands.
    private static let pause: useconds_t = 50_000

    static var isAvailable: Bool { symbols != nil }

    // MARK: Finding screens

    /// The channels of the external screens, in registry order. Each
    /// screen's framebuffer entry, which carries its EDID, comes just before
    /// its channel.
    static func channels() -> [Channel] {
        guard let symbols else { return [] }
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var channels: [Channel] = []
        var lastEDID: (vendor: UInt16, model: UInt16)?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            if let text = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, nil, 0)?.takeRetainedValue() as? String {
                lastEDID = edid(from: text)
                continue
            }
            var name = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &name)
            guard String(cString: name) == "DCPAVServiceProxy",
                  let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String,
                  location == "External",
                  let service = symbols.create(nil, entry)?.takeRetainedValue() else { continue }
            channels.append(Channel(vendor: lastEDID?.vendor ?? 0, model: lastEDID?.model ?? 0, service: service))
            lastEDID = nil
        }
        return channels
    }

    /// The first two fields of the EDID UUID are the manufacturer (big
    /// endian) and the product code (little endian), as in the EDID.
    static func edid(from uuid: String) -> (vendor: UInt16, model: UInt16)? {
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        guard hex.count >= 8, let vendor = UInt16(hex.prefix(4), radix: 16),
              let low = UInt16(hex.dropFirst(4).prefix(2), radix: 16),
              let high = UInt16(hex.dropFirst(6).prefix(2), radix: 16) else { return nil }
        return (vendor, high << 8 | low)
    }

    struct Screen: Equatable {
        let id: CGDirectDisplayID
        let vendor: UInt16
        let model: UInt16
    }

    /// Which channel belongs to which screen: by vendor and model, taking
    /// identical screens in order. A lone screen with a lone channel is
    /// paired even when the EDID could not be read. Returns the index in
    /// `channels` for each screen id.
    static func match(screens: [Screen], channels: [(vendor: UInt16, model: UInt16)]) -> [CGDirectDisplayID: Int] {
        var result: [CGDirectDisplayID: Int] = [:]
        var taken: Set<Int> = []
        for screen in screens.sorted(by: { $0.id < $1.id }) {
            guard let index = channels.indices.first(where: {
                !taken.contains($0) && channels[$0].vendor == screen.vendor && channels[$0].model == screen.model
            }) else { continue }
            taken.insert(index)
            result[screen.id] = index
        }
        if screens.count == 1, channels.count == 1, result.isEmpty { result[screens[0].id] = 0 }
        return result
    }

    // MARK: Brightness

    struct Level: Equatable {
        let value: Int
        let maximum: Int
    }

    func brightness(of channel: Channel) -> Level? {
        guard let symbols = Self.symbols else { return nil }
        for _ in 0..<3 {
            var request: [UInt8] = [0x82, 0x01, Self.brightnessCode]
            request.append(Self.checksum(of: request, seed: 0x6E ^ 0x51))
            let sent = symbols.write(channel.service, Self.chip, Self.dataAddress, &request, UInt32(request.count))
            usleep(Self.pause)
            var reply = [UInt8](repeating: 0, count: 12)
            let received = sent == kIOReturnSuccess
                ? symbols.read(channel.service, Self.chip, Self.dataAddress, &reply, UInt32(reply.count)) : sent
            if received == kIOReturnSuccess, let level = Self.level(from: reply) { return level }
            usleep(Self.pause)
        }
        return nil
    }

    @discardableResult
    func setBrightness(_ value: Int, of channel: Channel) -> Bool {
        guard let symbols = Self.symbols else { return false }
        let clamped = UInt16(min(max(value, 0), 0xFFFF))
        var command: [UInt8] = [0x84, 0x03, Self.brightnessCode, UInt8(clamped >> 8), UInt8(clamped & 0xFF)]
        command.append(Self.checksum(of: command, seed: 0x6E ^ 0x51))
        for _ in 0..<2 {
            let sent = symbols.write(channel.service, Self.chip, Self.dataAddress, &command, UInt32(command.count))
            usleep(Self.pause)
            if sent == kIOReturnSuccess { return true }
        }
        return false
    }

    /// A reply to "get VCP feature": 6E 88 02 result code type max max cur
    /// cur checksum. The checksum also covers the host address 0x50.
    static func level(from reply: [UInt8]) -> Level? {
        guard reply.count >= 11, reply[0] == 0x6E, reply[2] == 0x02, reply[3] == 0, reply[4] == brightnessCode,
              checksum(of: Array(reply[0..<10]), seed: 0x50) == reply[10] else { return nil }
        let maximum = Int(reply[6]) << 8 | Int(reply[7])
        let value = Int(reply[8]) << 8 | Int(reply[9])
        guard maximum > 0 else { return nil }
        return Level(value: min(value, maximum), maximum: maximum)
    }

    static func checksum(of bytes: [UInt8], seed: UInt8) -> UInt8 {
        bytes.reduce(seed, ^)
    }
}
