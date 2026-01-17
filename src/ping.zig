const std = @import("std");
const builtin = @import("builtin");

/// Pings a machine given a FQDN using the system's ping command in a multithreaded context.
/// The is_alive pointer is shared between threads, a mutex is used to ensure thread safety.
/// If ping_forever is true, run indefinitely with a 5 second sleep between pings.
pub fn ping_with_os_command_multithread(allocator: std.mem.Allocator, io: std.Io, alias_fqdn: []const u8, ping_forever: bool, mutex: *std.Thread.Mutex, is_alive: *bool) !void {
    while (true) {
        const ping_result = ping_with_os_command(allocator, io, alias_fqdn) catch |err| {
            return err;
        };

        // lock the mutex while updating the shared is_alive variable
        mutex.lock();
        is_alive.* = ping_result;
        mutex.unlock();

        if (!ping_forever) break;
        try std.Io.sleep(io, .fromSeconds(5), .real); // do not spam too many pings if pinging forever
    }
}

/// Pings a machine given a FQDN using the system's ping command, returns true if the ping was successful, false otherwise.
pub fn ping_with_os_command(allocator: std.mem.Allocator, io: std.Io, fqdn: []const u8) !bool {
    const args = switch (builtin.target.os.tag) {
        .linux, .macos => &[_][]const u8{ "ping", "-c", "1", "-W", "1", fqdn },
        .windows => &[_][]const u8{ "ping", "-n", "1", "-w", "1000", fqdn },
        else => @compileError("Unsupported OS"),
    };

    const result = try std.process.run(allocator, io, .{
        .argv = args,
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (result.term.exited == 0 and
        std.mem.indexOf(u8, result.stdout, "unreachable") == null and
        std.mem.indexOf(u8, result.stderr, "unreachable") == null)
    {
        return true;
    } else {
        return false;
    }
}

test "ping_with_os_command" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const gpa = da.allocator();

    try std.testing.expectEqual(true, try ping_with_os_command(gpa, "127.0.0.1"));
    try std.testing.expectEqual(true, try ping_with_os_command(gpa, "localhost"));
    try std.testing.expectEqual(false, try ping_with_os_command(gpa, "256.256.256.256"));
}
