const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

/// Pings an IP address with system's ping command, returns true if successful.
pub fn systemPingIpAddress(allocator: Allocator, io: Io, address: Io.net.IpAddress, result: *bool) Io.Cancelable!void {
    var buf: [255]u8 = undefined;
    const address_literal = switch (address) {
        .ip4 => blk: {
            const literal = std.fmt.bufPrint(&buf, "{f}", .{address.ip4}) catch return Io.Cancelable.Canceled;
            if (std.mem.findLast(u8, literal, ":")) |index| {
                break :blk literal[0..index];
            } else {
                break :blk literal;
            }
        },
        .ip6 => std.fmt.bufPrint(&buf, "{f}", .{address.ip6}) catch return Io.Cancelable.Canceled,
    };

    //std.log.info("address_literal -> {s}", .{address_literal});

    const args = switch (builtin.target.os.tag) {
        // On Windows, depend on PowerShell Test-NetConnection: it prints True to stdout if
        // the ICMP reached the target. Note: ping.exe does not distinguish (by exit code)
        // whether the ICMP reached the target or an intermediary.
        .windows => &[_][]const u8{ "PowerShell", "Test-NetConnection", address_literal, "-InformationLevel", "Quiet" },
        else => &[_][]const u8{ "ping", "-c", "1", "-W", "1", address_literal },
    };

    const run_result = std.process.run(allocator, io, .{
        .argv = args,
    }) catch return Io.Cancelable.Canceled;
    defer allocator.free(run_result.stderr);
    defer allocator.free(run_result.stdout);

    switch (builtin.target.os.tag) {
        .windows => result.* = run_result.term.exited == 0 and std.mem.find(u8, run_result.stdout, "True") == 0,
        else => result.* = run_result.term.exited == 0,
    }
}

/// Resolves a FQDN and pings it with system ping utility.
pub fn systemPingFqdn(allocator: Allocator, io: Io, fqdn: []const u8, result: *bool) Io.Cancelable!void {
    var address: ?Io.net.IpAddress = undefined;
    hostnameLookup(io, fqdn, &address) catch return Io.Cancelable.Canceled;
    if (address) |addr| {
        systemPingIpAddress(allocator, io, addr, result) catch return Io.Cancelable.Canceled;
    } else {
        result.* = false;
        return Io.Cancelable.Canceled;
    }
}

test "systemPingFqdn" {
    var result: bool = undefined;

    try systemPingFqdn(testing.allocator, testing.io, "127.0.0.1", &result);
    try testing.expect(result);

    try systemPingFqdn(testing.allocator, testing.io, "localhost", &result);
    try testing.expect(result);

    try testing.expectError(
        Io.Cancelable.Canceled,
        systemPingFqdn(testing.allocator, testing.io, "invalid hostname", &result),
    );

    try testing.expectError(
        Io.Cancelable.Canceled,
        systemPingFqdn(testing.allocator, testing.io, "256.256.256.256", &result),
    );
}

pub fn hostnameLookup(io: Io, fqdn: []const u8, result: *?Io.net.IpAddress) Io.Cancelable!void {
    Io.net.HostName.validate(fqdn) catch |err| {
        std.log.info("hostnameLookup: {s} -> {}", .{ fqdn, err });
        result.* = null;
        return Io.Cancelable.Canceled;
    };

    var buf_canonical_name: [255]u8 = undefined;
    var buf_lookup_result: [16]Io.net.HostName.LookupResult = undefined;
    var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&buf_lookup_result);

    Io.net.HostName.lookup(
        .{ .bytes = fqdn },
        io,
        &queue,
        .{ .canonical_name_buffer = &buf_canonical_name, .port = 0 },
    ) catch |err| {
        std.log.info("hostnameLookup: {s} -> {}", .{ fqdn, err });
        result.* = null;
        return Io.Cancelable.Canceled;
    };

    const lookup_result = queue.getOne(io) catch |err| {
        std.log.info("hostnameLookup: {s} -> {}", .{ fqdn, err });
        result.* = null;
        return Io.Cancelable.Canceled;
    };

    std.log.info("hostnameLookup: {s} -> {f}", .{ fqdn, lookup_result.address });
    result.* = lookup_result.address;
}

test "hostnameLookup localhost IPv6" {
    var result: ?Io.net.IpAddress = undefined;
    hostnameLookup(testing.io, "localhost", &result) catch |err| {
        std.log.info("hostnameLookup failed: {}", .{err});
        return;
    };

    switch (result.?) {
        .ip4 => return error.SkipZigTest,
        .ip6 => {
            const expected_ip = Io.net.IpAddress.parseLiteral("[::1]") catch unreachable;
            try testing.expect(std.mem.eql(u8, &result.?.ip6.bytes, &expected_ip.ip6.bytes));
        },
    }
}
