const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const log = std.log;
const testing = std.testing;
pub const Eui48 = @import("eui").Eui48;

pub fn generateMagicPacket(mac_bytes: [6]u8) [102]u8 {
    var packet: [102]u8 = undefined;
    @memset(packet[0..6], 0xFF); // First 6 bytes are 0xFF
    for (0..16) |i| {
        @memcpy(packet[6 + i * 6 .. 6 + (i + 1) * 6], &mac_bytes);
    }
    return packet;
}

/// Send a magic packet to wake up a device with the specified MAC address.
/// The broadcast address is expected as literal address:port, e.g. "255.255.255.255:9".
pub fn broadcastMagicPacket(io: Io, mac: []const u8, broadcast: ?[]const u8, count: ?u8) !void {
    // Defaults
    var actual_broadcast = try Io.net.IpAddress.parseLiteral(broadcast orelse "255.255.255.255:9");
    if (actual_broadcast.getPort() == 0) {
        log.warn("Provided broadcast address {f} has no port specified, defaulting to port 9.", .{actual_broadcast});
        actual_broadcast.setPort(9);
    }
    const actual_count = count orelse 3;

    const eui48 = Eui48.fromLiteral(mac) catch |err| {
        log.err("Invalid MAC address: {}", .{err});
        return err;
    };
    const magic_packet = generateMagicPacket(eui48.bytes);

    // Create a UDP socket
    const any_addr = Io.net.IpAddress.parse("0.0.0.0", 0) catch |err| {
        log.err("Failed to parse address: {}", .{err});
        return error.InvalidAddress;
    };
    const socket = Io.net.IpAddress.bind(
        &any_addr,
        io,
        .{
            .mode = .dgram,
            .protocol = .udp,
            .allow_broadcast = true,
        },
    ) catch |err| {
        log.err("Failed to bind UDP socket: {}", .{err});
        return err;
    };
    defer socket.close(io);

    // Send the magic packet
    for (0..actual_count) |_| {
        socket.send(io, &actual_broadcast, &magic_packet) catch |err| {
            log.err("Failed to send to the provided address {f}.", .{actual_broadcast.ip4});
            return err;
        };
    }

    log.info("Sent {d} magic packet to target MAC {s} via {f}/udp.", .{ actual_count, mac, actual_broadcast.ip4 });
}

/// Checks if a sequence is a valid magic packet: 6 bytes of 0xFF followed by the MAC address bytes repeated 16 times.
pub fn isMagicPacket(sequence: [102]u8) bool {
    // Check if the first 6 bytes are all 0xFF
    if (std.mem.eql(u8, sequence[0..6], &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }) == false) {
        return false;
    }

    // Check if the next 96 bytes are a MAC address repeated 16 times
    for (0..15) |j| {
        if (std.mem.eql(u8, sequence[6..12], sequence[12 + j * 6 .. 18 + j * 6]) == false) {
            return false;
        }
    }
    return true;
}

test "isMagicPacket (valid)" {
    const valid_packet: [102]u8 = [_]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
    };
    try testing.expect(isMagicPacket(valid_packet));
}

test "isMagicPacket (invalid - broken header)" {
    const invalid_packet_broken_header: [102]u8 = [_]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xAA, // broken header
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
    };
    try testing.expect(!isMagicPacket(invalid_packet_broken_header));
}

test "isMagicPacket (invalid - broken repetition)" {
    const invalid_packet_broken_repetition: [102]u8 = [_]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x01, 0x02, 0x03, 0x04, 0x05, 0xFF, // broken repetition
    };
    try testing.expect(!isMagicPacket(invalid_packet_broken_repetition));
}

/// Never returns. Listens for magic packets and relays them to the specified address and port.
pub fn relayBegin(io: Io, listen_addr: Io.net.IpAddress, relay_addr: Io.net.IpAddress) !void {
    const socket = Io.net.IpAddress.bind(
        &listen_addr,
        io,
        .{
            .mode = .dgram,
            .protocol = .udp,
            .allow_broadcast = true,
        },
    ) catch |err| {
        log.err("Failed to bind UDP socket to {f}: {}", .{ listen_addr.ip4, err });
        return err;
    };
    defer socket.close(io);

    log.info("Listening for WOL packets on {f}, relaying to {f}...", .{ listen_addr.ip4, relay_addr.ip4 });
    var buf: [102]u8 = undefined;
    while (true) {
        const incoming_message = socket.receive(io, &buf) catch continue;

        if (incoming_message.data.len != 102) {
            log.warn("Received packet with invalid size of {d} bytes, expected 102 bytes.", .{incoming_message.data.len});
            continue;
        }

        if (!isMagicPacket(buf)) {
            log.warn("Received packet ignored: invalid WOL packet.", .{});
            continue;
        }

        const mac: Eui48 = .{ .bytes = buf[6..12].* };
        log.info("Received WOL packet for MAC {f} on {f}, relaying to {f}", .{ mac, listen_addr.ip4, relay_addr.ip4 });

        _ = socket.send(io, &relay_addr, &buf) catch |err| {
            log.err("Failed to relay packet to {f}: {}", .{ relay_addr.ip4, err });
            return err;
        };

        try io.sleep(.fromMilliseconds(500), .real);
    }
}
