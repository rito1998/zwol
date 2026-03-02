const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

/// Pings a FQDN with system's ping command in a multithreaded context.
/// The is_alive points to a shared state array, a mutex is used for thread safety.
/// If forever, run indefinitely with a 5 second sleep between pings.
pub fn ping_with_os_command_multithread(allocator: Allocator, io: Io, fqdn: []const u8, forever: bool, mutex: *Io.Mutex, is_alive: *bool) !void {
    while (true) {
        const ping_result = ping_with_os_command(allocator, io, fqdn) catch |err| {
            return err;
        };

        // lock the mutex while updating the shared is_alive variable
        mutex.lockUncancelable(io);
        is_alive.* = ping_result;
        mutex.unlock(io);

        if (forever) {
            try io.sleep(.fromSeconds(5), .real); // do not spam too many pings if pinging forever
        } else break;
    }
    @compileError("deprecated");
}

/// Pings a FQDN with system's ping command, returns true if successful.
pub fn ping_with_os_command(allocator: Allocator, io: Io, fqdn: []const u8) anyerror!bool {
    const args = switch (builtin.target.os.tag) {
        // On Windows, depend on PowerShell Test-NetConnection: it prints True to stdout if
        // the ICMP reached the target. Note: ping.exe does not distinguish (by exit code)
        // whether the ICMP reached the target or an intermediary.
        .windows => &[_][]const u8{ "PowerShell", "Test-NetConnection", fqdn, "-InformationLevel", "Quiet" },
        else => &[_][]const u8{ "ping", "-c", "1", "-W", "1", fqdn },
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

test "ping_with_os_command" {
    try testing.expectEqual(true, try ping_with_os_command(testing.allocator, testing.io, "127.0.0.1"));
    try testing.expectEqual(true, try ping_with_os_command(testing.allocator, testing.io, "localhost"));
    try testing.expectEqual(false, try ping_with_os_command(testing.allocator, testing.io, "256.256.256.256"));
}
