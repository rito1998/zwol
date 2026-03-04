const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

/// Pings an IP address with system's ping command, returns true if successful.
pub fn systemPingIpAddress(allocator: Allocator, io: Io, address: Io.net.IpAddress) !bool {
    var buf: [255]u8 = undefined;
    const address_literal = switch (address) {
        .ip4 => blk: {
            const literal = try std.fmt.bufPrint(&buf, "{f}", .{address.ip4});
            if (std.mem.findLast(u8, literal, ":")) |index| {
                break :blk literal[0..index];
            } else {
                break :blk literal;
            }
        },
        .ip6 => try std.fmt.bufPrint(&buf, "{f}", .{address.ip6}),
    };

    //std.log.info("address_literal -> {s}", .{address_literal});

    const args = switch (builtin.target.os.tag) {
        // On Windows, depend on PowerShell Test-NetConnection: it prints True to stdout if
        // the ICMP reached the target. Note: ping.exe does not distinguish (by exit code)
        // whether the ICMP reached the target or an intermediary.
        .windows => &[_][]const u8{ "PowerShell", "Test-NetConnection", address_literal, "-InformationLevel", "Quiet" },
        else => &[_][]const u8{ "ping", "-c", "1", "-W", "1", address_literal },
    };

    const result = try std.process.run(allocator, io, .{
        .argv = args,
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (builtin.target.os.tag) {
        .windows => return result.term.exited == 0 and std.mem.find(u8, result.stdout, "True") == 0,
        else => return result.term.exited == 0,
    }
}

/// Resolves a FQDN and pings it with system ping utility.
pub fn systemPingFqdn(allocator: Allocator, io: Io, fqdn: []const u8, result: *bool) Io.Cancelable!void {
    const address = hostnameLookup(io, fqdn) catch return Io.Cancelable.Canceled;
    result.* = systemPingIpAddress(allocator, io, address) catch return Io.Cancelable.Canceled;
}

test "systemPingFqdn" {
    try testing.expectEqual(true, try systemPingFqdn(testing.allocator, testing.io, "127.0.0.1"));
    try testing.expectEqual(true, try systemPingFqdn(testing.allocator, testing.io, "localhost"));
    try testing.expectError(
        Io.net.HostName.ExpandError.InvalidHostName,
        systemPingFqdn(testing.allocator, testing.io, "invalid hostname"),
    );
    try testing.expectError(
        Io.net.HostName.ConnectError.UnknownHostName,
        systemPingFqdn(testing.allocator, testing.io, "256.256.256.256"),
    );
}

pub fn hostnameLookup(io: Io, fqdn: []const u8) !Io.net.IpAddress {
    try Io.net.HostName.validate(fqdn);

    var buf_canonical_name: [255]u8 = undefined;
    var buf_lookup_result: [16]Io.net.HostName.LookupResult = undefined;
    var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&buf_lookup_result);
    try Io.net.HostName.lookup(
        .{ .bytes = fqdn },
        io,
        &queue,
        .{ .canonical_name_buffer = &buf_canonical_name, .port = 0 },
    );

    const lookup_result = try queue.getOne(io);
    std.log.info("resolved {s} to {f}", .{ fqdn, lookup_result.address });

    return lookup_result.address;
}
