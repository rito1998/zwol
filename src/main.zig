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
    ping,
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
    \\-h, --help   Display this help and exit.
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

    // Set codepage to display emojis correctly on Windows
    if (builtin.target.os.tag == .windows) {
        var setcp = std.os.windows.CONSOLE.USER_IO.SET_CP(.Output, 65001);
        const ntstatus = try setcp.operate(io, null);
        if (ntstatus != .SUCCESS) {
            log.warn("Failed to set codepage 65001: characters may not display correctly.", .{});
        }
    }

    const subcommand = res.positionals[0] orelse return subCommandHelp(io);
    switch (subcommand) {
        .wake => try subCommandWake(allocator, io, &iter, res),
        .ping => try subCommandPing(allocator, io, &iter, res),
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
        \\--broadcast <str>   IpAddress, defaults to 255.255.255.255:9, setting this may be required in some scenarios.
        \\--all               Wake up all devices in the alias list.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        process.exit(1);
    };
    defer res.deinit();

    const help_message = "Provide a MAC or an alias name. Usage: zig-wol wake <MAC or ALIAS> [options]\n";

    if (res.args.help != 0)
        return try Io.File.stdout().writeStreamingAll(io, help_message);

    // if --all is provided, wake up all devices in the alias list
    if (res.args.all != 0) {
        var alias_list = alias.readAliasFile(allocator, io);
        defer alias_list.deinit(allocator);

        for (alias_list.items) |item| {
            try wol.broadcastMagicPacket(io, item.mac, item.broadcast, null);
            try Io.sleep(io, .fromMilliseconds(100), .real); // sleep between packets
        }
        return;
    }

    const mac = res.positionals[0] orelse return log.err("{s}", .{help_message});

    if (wol.isMacValid(mac)) {
        return try wol.broadcastMagicPacket(io, mac, res.args.broadcast, null);
    } else {
        var alias_list = alias.readAliasFile(allocator, io);
        defer alias_list.deinit(allocator);

        for (alias_list.items) |item| {
            if (item.name.len > 0 and item.name.len == mac.len) {
                if (std.mem.eql(u8, item.name, mac)) {
                    return try wol.broadcastMagicPacket(io, item.mac, item.broadcast, null);
                }
            }
        }

        log.err("Provided argument {s} is neither a valid MAC nor an existing alias name.", .{mac});
    }
}

fn subCommandPing(allocator: Allocator, io: Io, iter: *process.Args.Iterator, main_args: MainArgs) !void {
    _ = main_args;

    const params = comptime clap.parseParamsComptime(
        \\--forever   Ping continuously.
        \\--help      Display this help and exit.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        process.exit(1);
    };
    defer res.deinit();

    const help_message =
        \\Ping all aliases. Usage: zig-wol ping [--forever] [--help]
        \\Make sure a FQDN/IP is set accordingly for each alias.
    ;

    if (res.args.help != 0)
        return try Io.File.stdout().writeStreamingAll(io, help_message);

    const forever = res.args.forever != 0;

    var alias_list = alias.readAliasFile(allocator, io);
    defer alias_list.deinit(allocator);

    var is_alive = try allocator.alloc(bool, alias_list.items.len);
    for (is_alive) |*item| {
        item.* = false;
    }
    defer allocator.free(is_alive);

    var stdout_buf: [64]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    var stdout = &stdout_writer.interface;

    //try stdout.print("\u{1B}[?25l", .{}); // hide cursor

    var group = Io.Group.init;

    var idx: u64 = 0;
    while (true) {
        // launch async pings and await all futures
        for (alias_list.items, 0..) |item, i| {
            group.async(
                io,
                ping.systemPingFqdn,
                .{ allocator, io, item.fqdn, &is_alive[i] },
            );
        }
        try group.await(io);

        // reset the cursor to the top left before reprinting all lines
        if (forever and idx != 0) {
            try stdout.print("\u{1B}[{d}A\r", .{alias_list.items.len});
        }

        for (alias_list.items, 0..) |item, i| {
            if (is_alive[i]) {
                try stdout.print("{s}  {s}\n", .{ "\u{1F7E2}", item.name }); // Green circle: 🟢 (U+1F7E2)
            } else {
                try stdout.print("{s}  {s}\n", .{ "\u{1F534}", item.name }); // Red circle: 🔴 (U+1F534)
            }
        }
        try stdout.flush();

        if (forever) {
            // print running dots animation while waiting between pings
            try io.sleep(.fromMilliseconds(500), .real);
            try stdout.print(".", .{});
            try stdout.flush();
            try io.sleep(.fromMilliseconds(500), .real);
            try stdout.print(".", .{});
            try stdout.flush();
            try io.sleep(.fromMilliseconds(500), .real);
            try stdout.print(".", .{});
            try stdout.flush();
            try io.sleep(.fromMilliseconds(500), .real);
            try stdout.print("\u{1B}[3D   \u{1B}[3D", .{}); // delete the 3 dots
            try stdout.flush();
        } else break;
        idx += 1;
    }

    //try stdout.print("\u{1B}[?25h", .{}); // show cursor
    //try stdout.flush();
}

fn subCommandAlias(allocator: Allocator, io: Io, iter: *process.Args.Iterator, main_args: MainArgs) !void {
    _ = main_args;

    const params = comptime clap.parseParamsComptime(
        \\<str>                 Name for the new alias.
        \\<str>                 MAC for the new alias.
        \\--broadcast <str>     IpAddress, defaults to 255.255.255.255:9, setting this may be required in some scenarios.
        \\--fqdn <str>          Fully Qualified Domain Name or IP address. Required to ping for displaying the ping.
        \\--description <str>   Description for the new alias.
        \\-h, --help
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        process.exit(1);
    };
    defer res.deinit();

    const name = res.positionals[0] orelse return log.err("Provide name and MAC for the new alias. Usage: zig-wol alias <NAME> <MAC>", .{});
    const mac = res.positionals[1] orelse return log.err("Provide a MAC. Usage: zig-wol alias <NAME> <MAC>", .{});
    _ = wol.parseMac(mac) catch |err| {
        return log.err("Invalid MAC: {}", .{err});
    };
    const broadcast = res.args.broadcast orelse "255.255.255.255:9";
    const broadcast_addr = Io.net.IpAddress.parseLiteral(broadcast) catch |err| {
        return log.err("Invalid broadcast: {}. Must be in the form address:port, e.g. 255.255.255.255:9.", .{err});
    };
    if (broadcast_addr.getPort() == 0) {
        return log.err("Broadcast must include a port, e.g. 255.255.255.255:9.", .{});
    }
    const fqdn = res.args.fqdn orelse "";
    const description = res.args.description orelse "";

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
        process.exit(1);
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

    const help_message =
        \\Provide an alias name to remove. Usage: zig-wol remove <NAME>
        \\To remove all aliases: zig-wol remove --all
    ;

    if (res.args.help != 0)
        return try Io.File.stdout().writeStreamingAll(io, help_message);

    // if name len is 0 or --help is provided, print help message
    if (name.len == 0) {
        return log.err("Provide an alias name.", .{});
    }

    // finally, if a name is provided, remove the alias
    var alias_list = alias.readAliasFile(allocator, io);
    defer alias_list.deinit(allocator);

    for (alias_list.items, 0..) |item, idx| {
        if (std.mem.eql(u8, item.name, name)) {
            _ = alias_list.orderedRemove(idx);
            alias.writeAliasFile(allocator, io, alias_list);
            return log.info("Alias removed.", .{});
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
        process.exit(1);
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
        try stdout.interface.print("Name: {s}\nMAC: {s}\nBroadcast: {s}\nFQDN: {s}\nDescription: {s}\n\n", .{
            item.name,
            item.mac,
            item.broadcast,
            item.fqdn,
            item.description,
        });
    }
}

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
        process.exit(1);
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

    wol.relayBegin(io, listen, relay) catch |err| {
        return log.err("Failed to start relay: {}", .{err});
    };
}

fn subCommandVersion(io: Io) !void {
    const version = comptime try std.SemanticVersion.parse(build_zig_zon.version);
    const version_string = std.fmt.comptimePrint("{f}\n", .{version});
    try Io.File.stdout().writeStreamingAll(io, version_string);
}

fn subCommandHelp(io: Io) !void {
    const message =
        \\Usage: zig-wol <command> [options]
        \\Commands:
        \\  wake      Wake up a device by its MAC.
        \\  ping      Ping all aliases.
        \\  alias     Create an alias for a MAC, optionally specify a broadcast and a FQDN.
        \\  remove    Remove an alias by name.
        \\  list      List all aliases.
        \\  relay     Start listening for wol packets and relay them.
        \\  version   Display the version of the program.
        \\  help      Display help for the program or a specific command.
        \\
        \\Run 'zig-wol <command> --help' for more information on a specific command.
        \\
    ;
    try Io.File.stdout().writeStreamingAll(io, message);
}
