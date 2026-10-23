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

    // MARK: Features

    struct Level: Equatable {
        let value: Int
        let maximum: Int
    }

    static let brightnessCode: UInt8 = 0x10
    /// "Select color preset": sRGB, 6500 K, a user preset, and so on.
    static let colorPresetCode: UInt8 = 0x14

    func brightness(of channel: Channel) -> Level? { feature(Self.brightnessCode, of: channel) }

    @discardableResult
    func setBrightness(_ value: Int, of channel: Channel) -> Bool {
        setFeature(Self.brightnessCode, to: value, of: channel)
    }

    /// Reads one VCP feature. A screen that says it does not have the
    /// feature is not asked again.
    func feature(_ code: UInt8, of channel: Channel) -> Level? {
        guard let symbols = Self.symbols else { return nil }
        for _ in 0..<3 {
            var request: [UInt8] = [0x82, 0x01, code]
            request.append(Self.checksum(of: request, seed: 0x6E ^ 0x51))
            let sent = symbols.write(channel.service, Self.chip, Self.dataAddress, &request, UInt32(request.count))
            usleep(Self.pause)
            var reply = [UInt8](repeating: 0, count: 12)
            let received = sent == kIOReturnSuccess
                ? symbols.read(channel.service, Self.chip, Self.dataAddress, &reply, UInt32(reply.count)) : sent
            if received == kIOReturnSuccess {
                switch Self.parse(reply, code: code) {
                case let .level(level): return level
                case .unsupported: return nil
                case .invalid: break
                }
            }
            usleep(Self.pause)
        }
        return nil
    }

    @discardableResult
    func setFeature(_ code: UInt8, to value: Int, of channel: Channel) -> Bool {
        guard let symbols = Self.symbols else { return false }
        let clamped = UInt16(min(max(value, 0), 0xFFFF))
        var command: [UInt8] = [0x84, 0x03, code, UInt8(clamped >> 8), UInt8(clamped & 0xFF)]
        command.append(Self.checksum(of: command, seed: 0x6E ^ 0x51))
        for _ in 0..<2 {
            let sent = symbols.write(channel.service, Self.chip, Self.dataAddress, &command, UInt32(command.count))
            usleep(Self.pause)
            if sent == kIOReturnSuccess { return true }
        }
        return false
    }

    enum Reply: Equatable {
        case level(Level)
        /// The screen answered that it does not have this feature.
        case unsupported
        case invalid
    }

    /// A reply to "get VCP feature": 6E 88 02 result code type max max cur
    /// cur checksum. The checksum also covers the host address 0x50.
    static func parse(_ reply: [UInt8], code: UInt8) -> Reply {
        guard reply.count >= 11, reply[0] == 0x6E, reply[2] == 0x02, reply[4] == code,
              checksum(of: Array(reply[0..<10]), seed: 0x50) == reply[10] else { return .invalid }
        guard reply[3] == 0 else { return reply[3] == 1 ? .unsupported : .invalid }
        let maximum = Int(reply[6]) << 8 | Int(reply[7])
        let value = Int(reply[8]) << 8 | Int(reply[9])
        guard maximum > 0 else { return .invalid }
        return .level(Level(value: min(value, maximum), maximum: maximum))
    }

    static func level(from reply: [UInt8]) -> Level? {
        if case let .level(level) = parse(reply, code: brightnessCode) { return level }
        return nil
    }

    static func checksum(of bytes: [UInt8], seed: UInt8) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    // MARK: Capabilities

    /// The text a screen gives about itself, for example
    /// `(prot(monitor)vcp(10 12 14(01 05 0B) 60(01 03))mccs_ver(2.1))`. It
    /// arrives in pieces of up to 32 bytes.
    func capabilities(of channel: Channel) -> String? {
        guard let symbols = Self.symbols else { return nil }
        var text: [UInt8] = []
        var offset = 0
        for _ in 0..<64 {
            var request: [UInt8] = [0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)]
            request.append(Self.checksum(of: request, seed: 0x6E ^ 0x51))
            var piece: [UInt8]?
            for _ in 0..<4 {
                let sent = symbols.write(channel.service, Self.chip, Self.dataAddress, &request, UInt32(request.count))
                usleep(Self.pause)
                var reply = [UInt8](repeating: 0, count: 38)
                if sent == kIOReturnSuccess,
                   symbols.read(channel.service, Self.chip, Self.dataAddress, &reply, UInt32(reply.count)) == kIOReturnSuccess,
                   let found = Self.capabilitiesPiece(from: reply) {
                    piece = found
                    break
                }
                usleep(Self.pause)
            }
            guard let piece else { return nil }
            if piece.isEmpty { return String(decoding: text, as: UTF8.self) }
            text += piece
            offset += piece.count
        }
        return nil
    }

    /// 6E len E3 offset offset data... checksum. An empty piece ends the text.
    static func capabilitiesPiece(from reply: [UInt8]) -> [UInt8]? {
        guard reply.count >= 6, reply[0] == 0x6E, reply[2] == 0xE3 else { return nil }
        let count = Int(reply[1] & 0x7F) - 3
        guard count >= 0, 5 + count < reply.count,
              checksum(of: Array(reply[0..<(5 + count)]), seed: 0x50) == reply[5 + count] else { return nil }
        return Array(reply[5..<(5 + count)])
    }

    /// The features inside `vcp(...)`, each with the values it allows (empty
    /// for a feature that is a plain range).
    static func features(in capabilities: String) -> [UInt8: [UInt8]] {
        guard let start = capabilities.range(of: "vcp(") else { return [:] }
        let body = Array(capabilities[start.upperBound...])
        func hex(_ index: Int) -> UInt8? {
            guard index + 1 < body.count else { return nil }
            return UInt8(String(body[index...index + 1]), radix: 16)
        }
        var result: [UInt8: [UInt8]] = [:]
        var index = 0
        while index < body.count, body[index] != ")" {
            guard body[index] != " ", let code = hex(index) else { index += 1; continue }
            index += 2
            var values: [UInt8] = []
            if index < body.count, body[index] == "(" {
                index += 1
                while index < body.count, body[index] != ")" {
                    if body[index] != " ", let value = hex(index) { values.append(value); index += 2 } else { index += 1 }
                }
                index += 1
            }
            result[code] = values
        }
        return result
    }
}
