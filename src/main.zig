const std = @import("std");
const builtin = @import("builtin");
const build_zig_zon = @import("build_zig_zon");
const clap = @import("clap");
const wol = @import("wol.zig");
const alias = @import("alias.zig");
const ping = @import("ping.zig");

const debug = std.debug;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const process = std.process;
const log = std.log;

const SubCommands = enum {
    wake,
    status,
    alias,
    remove,
    list,
    relay,
    version,
    help,
};
const main_parsers = .{
    .command = clap.parsers.enumeration(SubCommands),
};
const main_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>
    \\
);
const MainArgs = clap.ResultEx(clap.Help, &main_params, main_parsers);

pub fn main(init: process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var iter = try init.minimal.args.iterateAllocator(allocator);
    defer iter.deinit();
    _ = iter.next(); // skip program name

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return subCommandHelp(io);
    };
    defer res.deinit();

    if (res.positionals.len == 0) {
        return subCommandHelp(io);
    }

    const subcommand = res.positionals[0] orelse return subCommandHelp(io);
    switch (subcommand) {
        .wake => try subCommandWake(allocator, io, &iter, res),
        .status => try subCommandStatus(allocator, io, &iter, res),
        .alias => try subCommandAlias(allocator, io, &iter, res),
        .remove => try subCommandRemove(allocator, io, &iter, res),
        .list => try subCommandList(allocator, io, &iter, res),
        .relay => try subCommandRelay(allocator, io, &iter, res),
        .version => try subCommandVersion(io),
        .help => try subCommandHelp(io),
    }
}

fn subCommandWake(allocator: Allocator, io: Io, iter: *process.Args.Iterator, main_args: MainArgs) !void {
    _ = main_args;

    const params = comptime clap.parseParamsComptime(
        \\<str>               MAC of the device to wake up, or an existing alias name.
        \\--help              Display this help and exit.
        \\--broadcast <str>   IPv4, defaults to 255.255.255.255, setting this may be required in some scenarios.
        \\--port <u16>        UDP port, default 9. Generally irrelevant since wake-on-lan works with OSI layer 2 (Data Link).
        \\--all               Wake up all devices in the alias list.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    const help_message = "Provide a MAC or an alias name. Usage: zig-wol wake <MAC or ALIAS> [options]\n";

    if (res.args.help != 0)
        return debug.print("{s}", .{help_message});

    // if --all is provided, wake up all devices in the alias list
    if (res.args.all != 0) {
        var alias_list = alias.readAliasFile(allocator, io);
        defer alias_list.deinit(allocator);

        for (alias_list.items) |item| {
            try wol.broadcast_magic_packet_ipv4(io, item.mac, item.port, item.broadcast, null);
            try Io.sleep(io, .fromMilliseconds(100), .real); // sleep between packets
        }
        return;
    }

    const mac = res.positionals[0] orelse return debug.print("{s}", .{help_message});

    if (wol.is_mac_valid(mac)) {
        return try wol.broadcast_magic_packet_ipv4(io, mac, res.args.port, res.args.broadcast, null);
    } else {
        var alias_list = alias.readAliasFile(allocator, io);
        defer alias_list.deinit(allocator);

        for (alias_list.items) |item| {
            if (item.name.len > 0 and item.name.len == mac.len) {
                if (std.mem.eql(u8, item.name, mac)) {
                    return try wol.broadcast_magic_packet_ipv4(io, item.mac, item.port, item.broadcast, null);
                }
            }
        }

        log.err("Provided argument {s} is neither a valid MAC nor an existing alias name.", .{mac});
    }
}

fn subCommandStatus(allocator: Allocator, io: Io, iter: *process.Args.Iterator, main_args: MainArgs) !void {
    _ = main_args;

    const params = comptime clap.parseParamsComptime(
        \\--live            Ping continuously.
        \\--help            Display this help and exit.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    const help_message =
        \\Ping all aliases to check their status. Usage: zig-wol status [--live] [--help]
        \\Make sure a FQDN/IP is set accordingly for each alias.
    ;

    if (res.args.help != 0)
        return debug.print("{s}", .{help_message});

    const is_status_live = res.args.live != 0;

    var alias_list = alias.readAliasFile(allocator, io);
    defer alias_list.deinit(allocator);

    var threads = try allocator.alloc(std.Thread, alias_list.items.len);
    defer allocator.free(threads);

    var is_alive_array = try allocator.alloc(bool, alias_list.items.len);
    for (is_alive_array) |*item| {
        item.* = false;
    }
    defer allocator.free(is_alive_array);

    var mutex = Io.Mutex.init;
    for (alias_list.items, 0..) |item, i| {
        threads[i] = try std.Thread.spawn(.{}, ping.ping_with_os_command_multithread, .{
            allocator,
            io,
            item.fqdn,
            is_status_live,
            &mutex,
            &is_alive_array[i],
        });
    }

    if (is_status_live) {
        // in live mode detach threads so they can run independently forever
        for (threads) |thread| {
            _ = thread.detach();
        }
    } else {
        // in non-live mode (one ping only) wait for all threads to finish.
        for (threads) |thread| {
            _ = thread.join();
        }
    }

    // Set codepage to display emojis correctly on Windows
    if (builtin.target.os.tag == .windows) {
        var setcp = std.os.windows.CONSOLE.USER_IO.SET_CP(.Output, 65001);
        const ntstatus = try setcp.operate(io, null);
        if (ntstatus != .SUCCESS) {
            log.warn("Failed to set codepage 65001: characters may not display correctly.", .{});
        }
    }

    var buf: [64]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &buf);
    var stdout = &stdout_writer.interface;

    try stdout.print("\u{1B}[?25l", .{}); // hide cursor

    var idx: u64 = 0;
    while (true) {
        // reset the cursor to the top left before reprinting all lines
        if (res.args.live != 0 and idx != 0) {
            try stdout.print("\u{1B}[{d}A\r", .{alias_list.items.len});
        }

        // while accessing the results array to print the status, lock the mutex
        mutex.lockUncancelable(io);
        for (alias_list.items, 0..) |item, i| {
            if (is_alive_array[i]) {
                try stdout.print("{s}  {s}\n", .{ "\u{1F7E2}", item.name }); // Green circle: 🟢 (U+1F7E2)
            } else {
                try stdout.print("{s}  {s}\n", .{ "\u{1F534}", item.name }); // Red circle: 🔴 (U+1F534)
            }
        }
        mutex.unlock(io);

        try stdout.flush();

        if (is_status_live) {
            // sleep between each console update
            try Io.sleep(io, .fromSeconds(1), .real);
        } else {
            break;
        }
        idx += 1;
    }
}

fn subCommandAlias(allocator: Allocator, io: Io, iter: *process.Args.Iterator, main_args: MainArgs) !void {
    _ = main_args;

    const params = comptime clap.parseParamsComptime(
        \\<str>                 Name for the new alias.
        \\<str>                 MAC for the new alias.
        \\--broadcast <str>     IPv4, defaults to 255.255.255.255, setting this may be required in some scenarios.
        \\--port <u16>          UDP port, default 9. Generally irrelevant since wake-on-lan works with OSI layer 2 (Data Link).
        \\--fqdn <str>          Fully Qualified Domain Name or IP address. Required to ping for displaying the status.
        \\--description <str>   Description for the new alias.
        \\-h, --help
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    const name = res.positionals[0] orelse return log.err("Provide name and MAC for the new alias. Usage: zig-wol alias <NAME> <MAC>", .{});
    const mac = res.positionals[1] orelse return log.err("Provide a MAC. Usage: zig-wol alias <NAME> <MAC>", .{});
    const broadcast = res.args.broadcast orelse "255.255.255.255";
    const port = res.args.port orelse 9;
    const fqdn = res.args.fqdn orelse "";
    const description = res.args.description orelse "";

    _ = wol.parse_mac(mac) catch |err| {
        return log.err("Invalid MAC: {}", .{err});
    };

    // get config from file, add alias and save config to file
    var alias_list = alias.readAliasFile(allocator, io);
    defer alias_list.deinit(allocator);

    // check if alias already exists
    for (alias_list.items) |item| {
        if (std.mem.eql(u8, item.name, name)) {
            return log.err("Failed to add alias: name already exists.", .{});
        }
    }

    alias_list.append(allocator, alias.Alias{
        .name = name,
        .mac = mac,
        .broadcast = broadcast,
        .port = port,
        .fqdn = fqdn,
        .description = description,
    }) catch |err| {
        return log.err("Failed to add alias: {}", .{err});
    };
    alias.writeAliasFile(allocator, io, alias_list);

    log.info("Alias added.", .{});
}

fn subCommandRemove(allocator: Allocator, io: Io, iter: *process.Args.Iterator, main_args: MainArgs) !void {
    _ = main_args;

    const params = comptime clap.parseParamsComptime(
        \\<str>?       Name of the alias to be removed.
        \\--all        Remove all aliases.
        \\-h, --help
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    const name = res.positionals[0] orelse "";

    // if --all is provided, remove all aliases
    if (res.args.all != 0) {
        var alias_list = alias.readAliasFile(allocator, io);
        const alias_count = alias_list.items.len;
        defer alias_list.deinit(allocator);

        alias_list.clearAndFree(allocator);
        alias.writeAliasFile(allocator, io, alias_list);
        log.info("Removed {d} aliases.", .{alias_count});
        return;
    }

    // if name len is 0 or --help is provided, print help message
    if (name.len == 0 or res.args.help != 0) {
        debug.print("Provide an alias name to remove. Usage: zig-wol remove <NAME>\n", .{});
        return debug.print("To remove all aliases: zig-wol remove --all\n", .{});
    }

    // finally, if a name is provided, remove the alias
    var alias_list = alias.readAliasFile(allocator, io);
    defer alias_list.deinit(allocator);

    for (alias_list.items, 0..) |item, idx| {
        if (std.mem.eql(u8, item.name, name)) {
            _ = alias_list.orderedRemove(idx);
            alias.writeAliasFile(allocator, io, alias_list);
            log.info("Alias removed.", .{});
            return;
        }
    }
    log.err("Alias not found.", .{});
}

fn subCommandList(allocator: Allocator, io: Io, iter: *process.Args.Iterator, main_args: MainArgs) !void {
    _ = main_args;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    var alias_list = alias.readAliasFile(allocator, io);
    defer alias_list.deinit(allocator);

    var buf: [64]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    defer stdout.interface.flush() catch |err| {
        log.err("Failed to flush stdout: {}", .{err});
    };

    for (alias_list.items) |item| {
        try stdout.interface.print("Name: {s}\nMAC: {s}\nBroadcast: {s}\nPort: {d}\nFQDN: {s}\nDescription: {s}\n\n", .{
            item.name,
            item.mac,
            item.broadcast,
            item.port,
            item.fqdn,
            item.description,
        });
    }
}

// TODO: proposal simplify the parameters by accepting IpAddress like "192.168.0.1:9"
fn subCommandRelay(allocator: Allocator, io: Io, iter: *process.Args.Iterator, main_args: MainArgs) !void {
    _ = main_args;

    const params = comptime clap.parseParamsComptime(
        \\--help   Display this help and exit.
        \\<str>    IpAddress to listen on, in format host:port, e.g. 192.168.0.10:9999.
        \\<str>    IpAddress to relay to, in format host:port, normally the subnet broadcast, e.g. 192.168.0.255:9.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    const help_message =
        \\Relay mode: listen for Wake-on-LAN packets and forward them.
        \\Usage: zig-wol relay <LISTEN_ADDR> <RELAY_ADDR> [--help]
        \\
        \\Options:
        \\  --help            Display this help and exit.
        \\
        \\Example:
        \\  zig-wol relay 192.168.0.10:9999 192.168.0.255:9
        \\
    ;

    if (res.args.help != 0)
        return debug.print("{s}", .{help_message});

    const listen_literal = res.positionals[0] orelse {
        log.err("Provide a listen address.", .{});
        return debug.print("{s}", .{help_message});
    };
    const relay_literal = res.positionals[1] orelse {
        log.err("Provide a relay address.", .{});
        return debug.print("{s}", .{help_message});
    };

    const listen = Io.net.IpAddress.parseLiteral(listen_literal) catch |err| {
        log.err("Invalid listen address: {}", .{err});
        return debug.print("{s}", .{help_message});
    };
    const relay = Io.net.IpAddress.parseLiteral(relay_literal) catch |err| {
        log.err("Invalid relay address: {}", .{err});
        return debug.print("{s}", .{help_message});
    };

    wol.relay_begin(io, listen, relay) catch |err| {
        return log.err("Failed to start relay: {}", .{err});
    };
}

fn subCommandVersion(io: Io) !void {
    const version = try std.SemanticVersion.parse(build_zig_zon.version);

    var buf: [64]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);

    try stdout.interface.print("{f}\n", .{version});
    try stdout.interface.flush();
}

fn subCommandHelp(io: Io) !void {
    const message =
        \\Usage: zig-wol <command> [options]
        \\Commands:
        \\  wake      Wake up a device by its MAC.
        \\  status    Ping all aliases.
        \\  alias     Create an alias for a MAC, optionally specify a broadcast, FQDN and more.
        \\  remove    Remove an alias by name.
        \\  list      List all aliases.
        \\  relay     Start listening for wol packets and relay them.
        \\  version   Display the version of the program.
        \\  help      Display help for the program or a specific command.
        \\
        \\Run 'zig-wol <command> --help' for more information on a specific command.
        \\
    ;
    try std.Io.File.stdout().writeStreamingAll(io, message);
}
