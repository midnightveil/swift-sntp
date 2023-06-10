// A simple unicast SNTP server, as described by https://datatracker.ietf.org/doc/html/rfc4330#section-5

import Foundation
import NIO
import SwiftyBytes

// Number of seconds between 1 Jan, 1900 (NTP Epoch) and 1 Jan, 1970 (Unix Epoch)
let january1970: Double = 2208988800

let remoteAddress = try SocketAddress.makeAddressResolvingHost("pool.ntp.org", port: 123)

// https://datatracker.ietf.org/doc/html/rfc4330#section-4
struct NTPPacket: CustomStringConvertible {
    private var firstByte: UInt8 = 0

    var leapIndicator: LeapIndicator {
        // First two bits (bits 0 and 1)
        get {
            // This should always work.
            LeapIndicator.init(rawValue: firstByte >> 6)!
        }
        set {
            firstByte = (firstByte & ~0b11_000_000) | (newValue.rawValue << 6)
        }
    }

    var versionNumber: VersionNumber {
        // Middle 3 bits (bits 2 to 4)
        get {
            // We panic on error here as it should always fall in the 3 bit int
            VersionNumber(rawValue: (firstByte & 0b00_111_000) >> 3)!
        }
        set {
            firstByte = (firstByte & ~0b00_111_000) | (newValue.rawValue << 3)
        }
    }

    var protocolMode: ProtocolMode {
        // Last 3 bits (bits 5 to 7)
        get {
            ProtocolMode(rawValue: firstByte & 0b00_000_111)!
        }
        set {
            firstByte = (firstByte & ~0b00_000_111) | (newValue.rawValue)
        }
    }

    let stratum: UInt8?
    let pollInterval: UInt8?
    let precision: UInt8?
    let rootDelay: UInt32?
    let rootDispersion: UInt32?
    let referenceIdentifier: UInt32?
    let referenceTimestamp: Date?
    let originateTimestamp: Date?
    let receiveTimestamp: Date?
    let transmitTimestamp: Date?

    // Create client packet
    init(transmitTimestamp: Date? = nil) {
        self.stratum = nil
        self.pollInterval = nil
        self.precision = nil
        self.rootDelay = nil
        self.rootDispersion = nil
        self.referenceIdentifier = nil
        self.referenceTimestamp = nil
        self.originateTimestamp = nil
        self.receiveTimestamp = nil
        self.transmitTimestamp = transmitTimestamp

        // This has to be at the end :(
        self.leapIndicator = .noWarning
        self.versionNumber = .version4
        self.protocolMode = .client
    }

    init(fromReader reader: BinaryReader) throws {
        self.firstByte = try reader.readUInt8()
        self.stratum = try reader.readUInt8()
        self.pollInterval = try reader.readUInt8()
        self.precision = try reader.readUInt8()
        self.rootDelay = try reader.readUInt32(true)
        self.rootDispersion = try reader.readUInt32(true)
        self.referenceIdentifier = try reader.readUInt32(true)
        self.referenceTimestamp = try reader.readTimestamp()
        self.originateTimestamp = try reader.readTimestamp()
        self.receiveTimestamp = try reader.readTimestamp()
        self.transmitTimestamp = try reader.readTimestamp()
    }

    func write(toWriter writer: BinaryWriter) throws {
        _ = try writer.writeUInt8(self.firstByte)
        _ = try writer.writeUInt8(self.stratum ?? 0)
        _ = try writer.writeUInt8(self.pollInterval ?? 0)
        _ = try writer.writeUInt8(self.precision ?? 0)
        _ = try writer.writeUInt32(self.rootDelay ?? 0, bigEndian: true)
        _ = try writer.writeUInt32(self.rootDispersion ?? 0, bigEndian: true)
        _ = try writer.writeUInt32(self.referenceIdentifier ?? 0, bigEndian: true)

        try writer.writeTimestamp(self.referenceTimestamp)
        try writer.writeTimestamp(self.originateTimestamp)
        try writer.writeTimestamp(self.receiveTimestamp)
        try writer.writeTimestamp(self.transmitTimestamp)
    }

    var description: String {
        return """
        \(Self.self)(
            leapIndicator: \(String(describing: leapIndicator)),
            versionNumber: \(versionNumber),
            protocolMode: \(protocolMode),
            stratum: \(String(describing: stratum)),
            pollInterval: \(String(describing: pollInterval)),
            precision: \(String(describing: precision)),
            rootDelay: \(String(describing: rootDelay)),
            rootDispersion: \(String(describing: rootDispersion)),
            referenceIdentifier: \(String(describing: referenceIdentifier)),
            referenceTimestamp: \(dateToStringWithSubseconds(referenceTimestamp ?? Date(timeIntervalSince1970: -january1970))),
            originateTimestamp: \(dateToStringWithSubseconds(originateTimestamp ?? Date(timeIntervalSince1970: -january1970))),
            receiveTimestamp: \(dateToStringWithSubseconds(receiveTimestamp ?? Date(timeIntervalSince1970: -january1970))),
            transmitTimestamp: \(dateToStringWithSubseconds(transmitTimestamp ?? Date(timeIntervalSince1970: -january1970))),
        )
        """
    }

    /*
      Timestamp Name          ID   When Generated
      ------------------------------------------------------------
      Originate Timestamp     T1   time request sent by client
      Receive Timestamp       T2   time request received by server
      Transmit Timestamp      T3   time reply sent by server
      Destination Timestamp   T4   time reply received by client

    The roundtrip delay d and system clock offset t are defined as:

      d = (T4 - T1) - (T3 - T2)     t = ((T2 - T1) + (T3 - T4)) / 2.
    */

    func calculateDelayMs(_ destinationTimestamp: Date) -> TimeInterval {
        let t4t1 = destinationTimestamp - originateTimestamp!
        let t3t2 = transmitTimestamp! - receiveTimestamp!
        return (t4t1 - t3t2) * 1000
    }

    func calculateOffsetMs(_ destinationTimestamp: Date) -> TimeInterval {
        let t2t1 = receiveTimestamp! - originateTimestamp!
        let t3t4 = transmitTimestamp! - destinationTimestamp

        return (t2t1 + t3t4) / 2 * 1000
    }
}

extension Date {
    public static func - (lhs: Date, rhs: Date) -> TimeInterval {
        return rhs.distance(to: lhs)
    }
}

enum LeapIndicator: UInt8 {
    case noWarning = 0
    case lastMinute61 = 1
    case lastMinute59 = 2
    case unknown = 3
}

enum VersionNumber: UInt8 {
    case version0 = 0
    case version1 = 1
    case version2 = 2
    case version3 = 3
    case version4 = 4
    // These don't actually exist (yet), but so it covers full range of 8bit int
    case version5 = 5
    case version6 = 6
    case version7 = 7
}

enum ProtocolMode: UInt8 {
    case reserved = 0
    case symmetricActive = 1
    case symmetricPassive = 2
    case client = 3
    case server = 4
    case broadcast = 5
    case ntpControlMessage = 6
    case reservedPrivateUse = 7
}   

func dateToStringWithSubseconds(_ date: Date) -> String{
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSS (ZZZZZ)"
    dateFormatter.timeZone = TimeZone(identifier: "Australia/Sydney")

    return dateFormatter.string(from: date)
}

// https://datatracker.ietf.org/doc/html/rfc4330#section-3
extension BinaryReader {
    public func readTimestamp() throws -> Date {
        let ntpSeconds = try self.readUInt32(true)
        let fractionBits = try self.readUInt32(true)
        
        // separately to prevent UInt32 overflow
        let unixSeconds = Double(ntpSeconds) - january1970
        let unixFraction = Double(fractionBits) / Double(1 << 32)

        let unixTime = unixSeconds + unixFraction

        return Date(timeIntervalSince1970: TimeInterval(unixTime))
    }
}

extension BinaryWriter {
    public func writeTimestamp(_ date: Date?) throws {
        if let date = date {
            let unixTime: Double = date.timeIntervalSince1970

            let (unixSeconds, unixFraction) = modf(unixTime)

            let ntpSeconds = UInt32(unixSeconds + january1970)
            let fractionBits = UInt32(unixFraction * Double(1 << 32))

            _ = try self.writeUInt32(ntpSeconds, bigEndian: true)
            _ = try self.writeUInt32(fractionBits, bigEndian: true)
        } else {
            _ = try self.writeUInt64(0)
        }
    }
}

private final class Handler: ChannelInboundHandler {
    // Inbound handler
    typealias InboundIn = AddressedEnvelope<NIO.ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<NIO.ByteBuffer>

    private var sentPacket: NTPPacket? = nil

    func channelActive(context: ChannelHandlerContext) {
        let packet = NTPPacket(transmitTimestamp: Date.now)
        print("Sent Packet to \(remoteAddress)\n\(packet)")
        sentPacket = packet

        let writer = BinaryWriter()
        try! packet.write(toWriter: writer)

        assert(writer.data.count == 48)

        let buffer = context.channel.allocator.buffer(bytes: writer.data.bytes)

        let envelope = OutboundOut(remoteAddress: remoteAddress, data: buffer)

        context.writeAndFlush(wrapOutboundOut(envelope), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let destinationTimestamp = Date.now
        let envelope = unwrapInboundIn(data)
        
        assert(envelope.remoteAddress == remoteAddress)

        let buffer = envelope.data

        let data = BinaryData(data: buffer.getBytes(at: 0, length: 48)!)

        let reader = BinaryReader(data)
        let packet = try! NTPPacket(fromReader: reader)

        print("Received Packet\n\(packet)")
        print("Roundtrip Delay: \(packet.calculateDelayMs(destinationTimestamp)) ms")
        print("Clock offset: \(packet.calculateOffsetMs(destinationTimestamp)) ms")

        /* TODO
        The server reply should be discarded if any of the LI, Stratum,
       or Transmit Timestamp fields is 0 or the Mode field is not 4
       (unicast) or 5 (broadcast).

        LI zero?????
        */

        print("""
        Sanity Checks:
        - Originate Timestamp in response matches Transmit in request: \(packet.originateTimestamp == sentPacket?.transmitTimestamp)
        - Response protocolMode is 4: \(packet.protocolMode == .server)
        - Stratum is not zero (kiss of death): \(packet.stratum != 0)
        - Transmit timestamp is not zero (1/Jan/1900): \(packet.transmitTimestamp?.timeIntervalSince1970 != -january1970)
        - Delay greater than zero: \(packet.calculateDelayMs(destinationTimestamp) > 0)
        """)

        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: \(error)")
        context.close(promise: nil)
    }
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
defer {
    try! group.syncShutdownGracefully()
}

let bootstrap = DatagramBootstrap(group: group)
                    .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .channelInitializer { channel in
                        channel.pipeline.addHandler(Handler())
                    }

let channel = try bootstrap.connect(to: remoteAddress).wait()

try channel.closeFuture.wait()  // Wait until the channel un-binds.