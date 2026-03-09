const std = @import("std");
const testing = std.testing;
const process = std.process;
const log = std.log;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

pub const Alias = struct {
    name: []const u8,
    mac: []const u8,
    broadcast: []const u8,
    fqdn: []const u8,
    description: []const u8,
};

/// Return the example alias list. Caller must free the memory after use.
fn getExampleAliasList(allocator: Allocator) ArrayList(Alias) {
    var alias_list = ArrayList(Alias).initCapacity(allocator, 0) catch |err| {
        log.err("Error initializing alias list: {}", .{err});
        process.exit(1);
    };

    alias_list.append(allocator, Alias{
        .name = "alias-example-unreachable",
        .mac = "01-01-01-ab-ab-ab",
        .broadcast = "255.255.255.255:9",
        .fqdn = "alias-example.unreachable-by-ping",
        .description = "Alias example. Supports WOL but cannot be pinged.",
    }) catch {
        log.err("Error appending to alias list", .{});
        process.exit(1);
    };

    alias_list.append(allocator, Alias{
        .name = "alias-example-localhost",
        .mac = "00-00-00-00-00-00",
        .broadcast = "255.255.255.255:9",
        .fqdn = "localhost",
        .description = "Alias example. Can be pinged but does not support WOL.",
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

    const file = Io.Dir.openFileAbsolute(io, file_path, .{ .mode = .read_only }) catch |err| {
        log.err("Error opening alias file: {}", .{err});
        process.exit(1);
    };
    defer file.close(io);

    const file_bytes = Io.Dir.readFileAlloc(.cwd(), io, file_path, allocator, .unlimited) catch |err| {
        log.err("Error opening alias file: {}", .{err});
        process.exit(1);
    };
    defer allocator.free(file_bytes);

    // Allocate a new null-terminated slice
    const file_source_nt = allocator.allocSentinel(u8, file_bytes.len, 0) catch |err| {
        log.err("Error allocating memory for alias file: {}", .{err});
        process.exit(1);
    };
    defer allocator.free(file_source_nt);

    @memcpy(file_source_nt[0..file_bytes.len], file_bytes);

    // Zon parsing
    var diagnostic: std.zon.parse.Diagnostics = .{};
    defer diagnostic.deinit(allocator);
    const alias_list_slice = std.zon.parse.fromSliceAlloc([]Alias, allocator, file_source_nt, &diagnostic, .{}) catch |err| {
        log.err("Error parsing alias file: {}", .{err});
        log.err("Zon parsing diagnostics:\n{f}", .{diagnostic});
        process.exit(1);
    };

    return ArrayList(Alias).fromOwnedSlice(alias_list_slice);
}

test "readAliasFile" {
    const allocator = testing.allocator;
    const io = testing.io;

    var alias_list = readAliasFile(allocator, io);
    defer alias_list.deinit(allocator);

    try testing.expect(alias_list.items.len >= 1);

    log.info("First alias: {s}, {s}, {s}", .{ alias_list.items[0].name, alias_list.items[0].mac, alias_list.items[0].description });

    try testing.expect(std.mem.eql(u8, alias_list.items[0].name, "alias-example-unreachable"));
    try testing.expect(std.mem.eql(u8, alias_list.items[0].mac, "01-01-01-ab-ab-ab"));
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

test "writeAliasFile" {
    const allocator = testing.allocator;
    const io = testing.io;

    var alias_list = getExampleAliasList(allocator);
    defer alias_list.deinit(allocator);
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

test "getAliasFilePath" {
    const allocator = testing.allocator;
    const io = testing.io;

    const file_path = getAliasFilePath(allocator, io);
    defer allocator.free(file_path);

    log.info("Alias file path: {s}\n", .{file_path});
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

test "aliasFileExists" {
    const allocator = testing.allocator;
    const io = testing.io;

    _ = aliasFileExists(allocator, io);
}
