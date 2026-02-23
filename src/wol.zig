const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const log = std.log;
const testing = std.testing;

/// Parse a MAC address string into an array of 6 bytes.
/// Expects length 17 and separator either "-" or ":" (e.g. 01-23-45-AB-CD-EF)
pub fn parse_mac(mac: []const u8) ![6]u8 {
    if (mac.len != 17) return error.InvalidMacAddress;

    // Expect either ':' or '-'
    const sep: u8 = mac[2];
    if (sep != ':' and sep != '-') return error.InvalidMacAddress;

    // Ensure all separators are the same
    var i: usize = 2;
    while (i < mac.len) : (i += 3) {
        if (mac[i] != sep) return error.InvalidMacAddress;
    }

    var mac_split_iterator = std.mem.tokenizeSequence(u8, mac, &.{sep});
    var mac_octets: [6]u8 = undefined;
    var idx: usize = 0;

    while (mac_split_iterator.next()) |mac_part| {
        if (idx >= 6) return error.InvalidMacAddress;
        mac_octets[idx] = std.fmt.parseInt(u8, mac_part, 16) catch return error.InvalidMacAddress;
        idx += 1;
    }

    if (idx != 6) return error.InvalidMacAddress;

    return mac_octets;
}

test "parse_mac valid cases" {
    try testing.expectEqual(parse_mac("01:23:45:67:89:ab"), [6]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab });
    try testing.expectEqual(parse_mac("01:23:45:67:89:Ab"), [6]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab });
    try testing.expectEqual(parse_mac("01:23:45:67:89:AB"), [6]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab });
    try testing.expectEqual(parse_mac("01-23-45-67-89-ab"), [6]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB });
    try testing.expectEqual(parse_mac("01-23-45-67-89-Ab"), [6]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB });
    try testing.expectEqual(parse_mac("01-23-45-67-89-AB"), [6]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB });
}

test "parse_mac invalid cases" {
    try testing.expectError(error.InvalidMacAddress, parse_mac("0123456789AB")); // No separators
    try testing.expectError(error.InvalidMacAddress, parse_mac("01:23:45:67:89")); // Too short
    try testing.expectError(error.InvalidMacAddress, parse_mac("01:23:45:67:89:AB:CD")); // Too long
    try testing.expectError(error.InvalidMacAddress, parse_mac("01:23:45:67:89:GG")); // Invalid hex
    try testing.expectError(error.InvalidMacAddress, parse_mac("01-23:45-67:89:AB")); // Mixed separators
    try testing.expectError(error.InvalidMacAddress, parse_mac("01::23:45:67:89:AB")); // Extra colon
    try testing.expectError(error.InvalidMacAddress, parse_mac("")); // Empty string
}

/// Expects length 17 and separator either "-" or ":" (e.g. 01-23-45-AB-CD-EF)
pub fn is_mac_valid(mac: []const u8) bool {
    _ = parse_mac(mac) catch return false;
    return true;
}

test "is_mac_valid" {
    try testing.expectEqual(is_mac_valid("01:23:45:67:89:ab"), true);
    try testing.expectEqual(is_mac_valid("01-23-45-67-89-ab"), true);
    try testing.expectEqual(is_mac_valid("01:23:45:67:89"), false); // Too short
    try testing.expectEqual(is_mac_valid("01:23:45:67:89:AB:CD"), false); // Too long
    try testing.expectEqual(is_mac_valid("01:23:45:67:89:GG"), false); // Invalid hex
    try testing.expectEqual(is_mac_valid("01-23:45-67-89:AB"), false); // Mixed separators
    try testing.expectEqual(is_mac_valid("01::23:45:67:89:AB"), false); // Extra colon
    try testing.expectEqual(is_mac_valid(""), false); // Empty string
}

pub fn generate_magic_packet(mac_bytes: [6]u8) [102]u8 {
    var packet: [102]u8 = undefined;
    @memset(packet[0..6], 0xFF); // First 6 bytes are 0xFF
    for (0..16) |i| {
        @memcpy(packet[6 + i * 6 .. 6 + (i + 1) * 6], &mac_bytes);
    }
    return packet;
}

/// Send a magic packet to wake up a device with the specified MAC address.
/// The broadcast address is expected as literal address:port, e.g. "255.255.255.255:9".
pub fn broadcast_magic_packet_ipv4(io: Io, mac: []const u8, broadcast: ?[]const u8, count: ?u8) !void {
    // Defaults
    const actual_broadcast = try Io.net.IpAddress.parseLiteral(broadcast orelse "255.255.255.255:9");
    const actual_count = count orelse 3; // how man times the magic packet is sent

    const mac_bytes = parse_mac(mac) catch |err| {
        log.err("Invalid MAC address: {}", .{err});
        return err;
    };
    const magic_packet = generate_magic_packet(mac_bytes);

    // Create a UDP socket
    const any_addr = Io.net.IpAddress.parse("0.0.0.0", 0) catch |err| {
        log.err("Failed to parse address: {}", .{err});
        return error.InvalidAddress;
    };
    const socket = Io.net.IpAddress.bind(&any_addr, io, .{ .mode = .dgram, .protocol = .udp }) catch |err| {
        log.err("Failed to bind UDP socket: {}", .{err});
        return err;
    };
    defer socket.close(io);

    // Enable socket broadcast
    const option_value: u32 = 1;
    posix.setsockopt(socket.handle, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&option_value)) catch |err| {
        log.err("Failed to set socket option to enable broadcast: {}", .{err});
        return err;
    };

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
pub fn is_magic_packet(sequence: [102]u8) bool {
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

test "is_magic_packet (valid)" {
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
    try testing.expect(is_magic_packet(valid_packet));
}

test "is_magic_packet (invalid - broken header)" {
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
    try testing.expect(!is_magic_packet(invalid_packet_broken_header));
}

test "is_magic_packet (invalid - broken repetition)" {
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
    try testing.expect(!is_magic_packet(invalid_packet_broken_repetition));
}

/// Never returns. Listens for magic packets and relays them to the specified address and port.
pub fn relay_begin(io: Io, listen_addr: Io.net.IpAddress, relay_addr: Io.net.IpAddress) !void {
    const socket = Io.net.IpAddress.bind(&listen_addr, io, .{
        .mode = .dgram,
        .protocol = .udp,
    }) catch |err| {
        log.err("Failed to bind UDP socket to {f}: {}\n", .{ listen_addr.ip4, err });
        return err;
    };
    defer socket.close(io);

    // Enable socket broadcast (setting SO_BROADCAST to anything othen than empty string enables broadcast)
    const option_value: u32 = 1;
    posix.setsockopt(socket.handle, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&option_value)) catch |err| {
        log.err("Failed to set socket option to enable broadcast: {}", .{err});
        return err;
    };

    var buf: [102]u8 = undefined;

    while (true) {
        try Io.sleep(io, .fromSeconds(1), .real);

        log.info("Listening for WOL packets on {f}, relaying to {f}...\n", .{ listen_addr.ip4, relay_addr.ip4 });

        const incoming_message = socket.receive(io, &buf) catch |err| {
            log.warn("Failed to receive data: {}\n", .{err});
            continue; // in case of recv error (e.g. error.MessageTooBig when size > 102 bytes), ignore and continue listening
        };

        if (incoming_message.data.len != 102) {
            log.warn("Received packet ignored: unexpected packet size of {d} bytes, expected 102 bytes.\n", .{incoming_message.data.len});
            continue; // ignore packets that are not 102 bytes
        }

        if (!is_magic_packet(buf)) {
            log.warn("Received packet ignored: invalid WOL packet.\n", .{});
            continue;
        }

        log.info("Received WOL packet on {f}.\nPacket data: {x}.\n\n", .{ listen_addr.ip4, buf[0..incoming_message.data.len] });
        // Relay the received magic packet to the specified address and port
        _ = socket.send(io, &relay_addr, &buf) catch |err| {
            log.err("Failed to relay to {f}: {}\n", .{ relay_addr.ip4, err });
            return err;
        };
    }
}
