const std = @import("std");
const testing = std.testing;
const process = std.process;
const debug = std.debug;
const log = std.log;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

pub const Alias = struct {
    name: []const u8,
    mac: []const u8,
    broadcast: []const u8,
    fqdn: []const u8,
};

/// Free all owned strings in an alias.
pub fn freeAlias(allocator: Allocator, value: Alias) void {
    allocator.free(value.name);
    allocator.free(value.mac);
    allocator.free(value.broadcast);
    allocator.free(value.fqdn);
}

/// Clone alias fields so they become allocator-owned.
pub fn cloneAlias(allocator: Allocator, value: Alias) !Alias {
    const name = try allocator.dupe(u8, value.name);
    errdefer allocator.free(name);

    const mac = try allocator.dupe(u8, value.mac);
    errdefer allocator.free(mac);

    const broadcast = try allocator.dupe(u8, value.broadcast);
    errdefer allocator.free(broadcast);

    const fqdn = try allocator.dupe(u8, value.fqdn);
    errdefer allocator.free(fqdn);

    return .{
        .name = name,
        .mac = mac,
        .broadcast = broadcast,
        .fqdn = fqdn,
    };
}

/// Append an alias after cloning all string fields.
pub fn appendAliasOwned(allocator: Allocator, alias_list: *ArrayList(Alias), value: Alias) !void {
    const cloned = try cloneAlias(allocator, value);
    errdefer freeAlias(allocator, cloned);
    try alias_list.append(allocator, cloned);
}

/// Deinitialize alias list and deeply free every alias field.
pub fn deinitAliasList(allocator: Allocator, alias_list: *ArrayList(Alias)) void {
    for (alias_list.items) |item| {
        freeAlias(allocator, item);
    }
    alias_list.deinit(allocator);
}

/// Return the example alias list. Caller must free the memory after use.
fn getExampleAliasList(allocator: Allocator) ArrayList(Alias) {
    var alias_list = ArrayList(Alias).initCapacity(allocator, 0) catch |err| {
        log.err("Error initializing alias list: {}", .{err});
        process.exit(1);
    };

    errdefer deinitAliasList(allocator, &alias_list);

    appendAliasOwned(allocator, &alias_list, Alias{
        .name = "home-server",
        .mac = "11-11-11-ab-ab-ab",
        .broadcast = "255.255.255.255:9",
        .fqdn = "192.168.0.1",
    }) catch {
        log.err("Error appending to alias list", .{});
        process.exit(1);
    };

    appendAliasOwned(allocator, &alias_list, Alias{
        .name = "workstation",
        .mac = "22-22-22-cd-cd-cd",
        .broadcast = "192.168.0.255:9",
        .fqdn = "workstation.home",
    }) catch {
        log.err("Error appending to alias list", .{});
        process.exit(1);
    };

    return alias_list;
}

/// Read the alias file in the same directory as the executable. Caller must free the memory after use.
pub fn readAliasFile(allocator: Allocator, io: Io) ArrayList(Alias) {
    const file_path = getAliasFilePath(allocator, io);
    defer allocator.free(file_path);

    if (!aliasFileExists(allocator, io)) {
        log.info("Alias list file does not exist, creating the default file...", .{});
        const example_alias_list = getExampleAliasList(allocator);
        writeAliasFile(allocator, io, example_alias_list.items);
        return example_alias_list;
    }

    const file_stats = Io.Dir.statFile(.cwd(), io, file_path, .{}) catch |err| {
        log.err("Error getting alias file size: {}", .{err});
        process.exit(1);
    };

    const buffer_nt: [:0]u8 = allocator.allocSentinel(u8, file_stats.size, 0) catch |err| {
        log.err("Error allocating memory for alias file: {}", .{err});
        process.exit(1);
    };
    defer allocator.free(buffer_nt);

    const slice_nt = Io.Dir.readFile(.cwd(), io, file_path, buffer_nt) catch |err| {
        log.err("Error reading alias file: {}", .{err});
        process.exit(1);
    };
    debug.assert(slice_nt.len == file_stats.size);

    const alias_list_slice = std.zon.parse.fromSliceAlloc(
        []Alias,
        allocator,
        buffer_nt,
        null,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.err("Error parsing alias file: {}", .{err});
        process.exit(1);
    };

    return ArrayList(Alias).fromOwnedSlice(alias_list_slice);
}

test readAliasFile {
    const allocator = testing.allocator;
    const io = testing.io;

    var alias_list = readAliasFile(allocator, io);
    defer deinitAliasList(allocator, &alias_list);

    try testing.expect(std.mem.eql(u8, alias_list.items[0].name, "home-server"));
    try testing.expect(std.mem.eql(u8, alias_list.items[0].mac, "11-11-11-ab-ab-ab"));
    try testing.expect(std.mem.eql(u8, alias_list.items[0].fqdn, "192.168.0.1"));
}

/// Write the alias file in the same directory as the executable. Overwrites if it already exists.
pub fn writeAliasFile(allocator: Allocator, io: Io, alias_slice: []Alias) void {
    const file_path = getAliasFilePath(allocator, io);
    defer allocator.free(file_path);

    const file = Io.Dir.createFileAbsolute(io, file_path, .{}) catch |err| {
        log.err("Error creating alias file: {}", .{err});
        process.exit(1);
    };
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var writer = Io.File.Writer.init(file, io, &buf);
    const writer_interface = &writer.interface;
    defer writer_interface.flush() catch |err| {
        log.err("Error flushing alias file: {}", .{err});
        process.exit(1);
    };

    std.zon.stringify.serialize(alias_slice, .{}, writer_interface) catch |err| {
        log.err("Error serializing alias file: {}", .{err});
        process.exit(1);
    };
}

test writeAliasFile {
    const allocator = testing.allocator;
    const io = testing.io;

    var alias_list = getExampleAliasList(allocator);
    defer deinitAliasList(allocator, &alias_list);
    writeAliasFile(allocator, io, alias_list.items);
}

/// Computes the absolute path to the alias file in the same directory as the executable.
/// Caller must free the memory after use.
pub fn getAliasFilePath(allocator: Allocator, io: Io) []u8 {
    const exe_dir_path = process.executableDirPathAlloc(io, allocator) catch |err| {
        log.err("Error getting self executable directory path: {}", .{err});
        process.exit(1);
    };
    defer allocator.free(exe_dir_path);

    const file_path = std.fs.path.join(allocator, &[_][]const u8{
        exe_dir_path,
        "alias.zon",
    }) catch |err| {
        log.err("Error joining paths: {}", .{err});
        process.exit(1);
    };

    return file_path;
}

test getAliasFilePath {
    const allocator = testing.allocator;
    const io = testing.io;

    const file_path = getAliasFilePath(allocator, io);
    defer allocator.free(file_path);
}

/// Check if the zon alias file exists in the same directory as the executable.
/// Internally allocates and frees to compute the path.
pub fn aliasFileExists(allocator: Allocator, io: Io) bool {
    const file_path = getAliasFilePath(allocator, io);
    defer allocator.free(file_path);

    _ = Io.Dir.accessAbsolute(io, file_path, .{ .read = true }) catch {
        return false;
    };

    return true;
}

test aliasFileExists {
    const allocator = testing.allocator;
    const io = testing.io;

    _ = aliasFileExists(allocator, io);
}
