const std = @import("std");
const posix = std.posix;

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
    try std.testing.expectEqual(parse_mac("01:23:45:67:89:ab"), [6]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab });
    try std.testing.expectEqual(parse_mac("01:23:45:67:89:Ab"), [6]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab });
    try std.testing.expectEqual(parse_mac("01:23:45:67:89:AB"), [6]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab });
    try std.testing.expectEqual(parse_mac("01-23-45-67-89-ab"), [6]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB });
    try std.testing.expectEqual(parse_mac("01-23-45-67-89-Ab"), [6]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB });
    try std.testing.expectEqual(parse_mac("01-23-45-67-89-AB"), [6]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB });
}

test "parse_mac invalid cases" {
    try std.testing.expectError(error.InvalidMacAddress, parse_mac("0123456789AB")); // No separators
    try std.testing.expectError(error.InvalidMacAddress, parse_mac("01:23:45:67:89")); // Too short
    try std.testing.expectError(error.InvalidMacAddress, parse_mac("01:23:45:67:89:AB:CD")); // Too long
    try std.testing.expectError(error.InvalidMacAddress, parse_mac("01:23:45:67:89:GG")); // Invalid hex
    try std.testing.expectError(error.InvalidMacAddress, parse_mac("01-23:45-67:89:AB")); // Mixed separators
    try std.testing.expectError(error.InvalidMacAddress, parse_mac("01::23:45:67:89:AB")); // Extra colon
    try std.testing.expectError(error.InvalidMacAddress, parse_mac("")); // Empty string
}

/// Expects length 17 and separator either "-" or ":" (e.g. 01-23-45-AB-CD-EF)
pub fn is_mac_valid(mac: []const u8) bool {
    _ = parse_mac(mac) catch return false;
    return true;
}

test "is_mac_valid" {
    try std.testing.expectEqual(is_mac_valid("01:23:45:67:89:ab"), true);
    try std.testing.expectEqual(is_mac_valid("01-23-45-67-89-ab"), true);
    try std.testing.expectEqual(is_mac_valid("01:23:45:67:89"), false); // Too short
    try std.testing.expectEqual(is_mac_valid("01:23:45:67:89:AB:CD"), false); // Too long
    try std.testing.expectEqual(is_mac_valid("01:23:45:67:89:GG"), false); // Invalid hex
    try std.testing.expectEqual(is_mac_valid("01-23:45-67-89:AB"), false); // Mixed separators
    try std.testing.expectEqual(is_mac_valid("01::23:45:67:89:AB"), false); // Extra colon
    try std.testing.expectEqual(is_mac_valid(""), false); // Empty string
}

pub fn generate_magic_packet(mac_bytes: [6]u8) [102]u8 {
    var packet: [102]u8 = undefined;
    @memset(packet[0..6], 0xFF); // First 6 bytes are 0xFF
    for (0..16) |i| {
        @memcpy(packet[6 + i * 6 .. 6 + (i + 1) * 6], &mac_bytes);
    }
    return packet;
}

/// Broadcasts a magic packet to wake up a device with the specified MAC address.
pub fn broadcast_magic_packet_ipv4(io: std.Io, mac: []const u8, port: ?u16, broadcast: ?[]const u8, count: ?u8) !void {
    std.log.err("UDP networking for magic packet not yet implemented for zig 0.16-master.", .{});

    _ = io; // currently unused

    // Defaults
    const actual_port = port orelse 9;
    const actual_broadcast = try std.Io.net.IpAddress.parse(broadcast orelse "255.255.255.255", actual_port);
    _ = actual_broadcast; // currently unused
    const actual_count = count orelse 3; // how man times the magic packet is sent
    _ = actual_count; // currently unused

    const mac_bytes = parse_mac(mac) catch |err| {
        std.log.err("Invalid MAC address: {}\n", .{err});
        return err;
    };
    const magic_packet = generate_magic_packet(mac_bytes);
    _ = magic_packet; // currently unused

    // // Create a UDP socket
    // const socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    // defer posix.close(socket);

    // // Enable socket broadcast (setting SO_BROADCAST to anything othen than empty string enables broadcast)
    // const option_value: u32 = 1;
    // posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&option_value)) catch |err| {
    //     std.log.err("Failed to set socket option to enable broadcast: {}\n", .{err});
    //     return err;
    // ;

    // // Send the magic packet
    // for (0..actual_count) |_| {
    //     _ = posix.sendto(socket, &magic_packet, 0, &actual_broadcast.any, actual_broadcast.getOsSockLen()) catch |err| {
    //         std.log.err("Failed to send to the provided address {f}.\n", .{actual_broadcast.in});
    //         return err;
    //     };
    // }

    // std.log.info("Sent {d} magic packet to target MAC {s} via {f}/udp.\n", .{ actual_count, mac, actual_broadcast.in });
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
    try std.testing.expect(is_magic_packet(valid_packet));
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
    try std.testing.expect(!is_magic_packet(invalid_packet_broken_header));
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
    try std.testing.expect(!is_magic_packet(invalid_packet_broken_repetition));
}

/// Never returns. Listens for magic packets and relays them to the specified address and port.
pub fn relay_begin(io: std.Io, listen_addr: std.Io.net.IpAddress, relay_addr: std.Io.net.IpAddress) !void {
    std.log.err("UDP networking for magic packet not yet implemented for zig 0.16-master.", .{});

    // const socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    // defer posix.close(socket);

    const option_value: u32 = 1;
    _ = option_value; // currently unused
    // try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&option_value));

    // posix.bind(socket, &listen_addr.any, listen_addr.getOsSockLen()) catch |err| {
    //     std.log.err("Failed to bind socket to {f}: {}\n", .{ listen_addr.in, err });
    //     return err;
    // };

    var buf: [102]u8 = undefined;
    buf[0] = 0; // prevent "variable 'buf' is uninitialized" compile error

    while (true) {
        try std.Io.sleep(io, .fromSeconds(1), .real);

        std.log.info("Listening for WOL packets on {f}, relaying to {f}...\n", .{ listen_addr.ip4, relay_addr.ip4 });

        // const received_bytes_count = posix.recv(socket, &buf, 0) catch |err| {
        //     std.log.err("Failed to receive data: {}\n", .{err});
        //     continue; // in case of recv error (e.g. error.MessageTooBig when size > 102 bytes), ignore and continue listening
        // };

        // if (received_bytes_count != 102) {
        //     std.log.info("Received packet ignored: unexpected packet size of {d} bytes, expected 102 bytes.\n", .{received_bytes_count});
        //     continue; // ignore packets that are not 102 bytes
        // }

        if (!is_magic_packet(buf)) {
            std.log.info("Received packet ignored: invalid WOL packet.\n", .{});
            continue;
        }

        // std.log.info("Received WOL packet on {f}.\nPacket data: {x}.\n\n", .{ listen_addr.in, buf[0..received_bytes_count] });
        // Relay the received magic packet to the specified address and port
        // _ = posix.sendto(socket, &buf, 0, &relay_addr.any, relay_addr.getOsSockLen()) catch |err| {
        //     std.log.err("Failed to relay to {f}.\n", .{relay_addr.in});
        //     return err;
        // };
    }
}
