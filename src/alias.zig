const std = @import("std");
const ArrayList = std.ArrayList;

pub const Alias = struct {
    name: []const u8,
    mac: []const u8,
    broadcast: []const u8,
    port: u16,
    fqdn: []const u8,
    description: []const u8,
};

/// Return the example alias list. Caller must free the memory after use.
fn getExampleAliasList(allocator: std.mem.Allocator) ArrayList(Alias) {
    var alias_list = ArrayList(Alias).initCapacity(allocator, 0) catch @panic("OutOfMemory");

    alias_list.append(allocator, Alias{
        .name = "alias-example-unreachable",
        .mac = "01-01-01-ab-ab-ab",
        .broadcast = "255.255.255.255",
        .port = 9,
        .fqdn = "alias-example.unreachable-by-ping",
        .description = "Alias example. Works with WOL but cannot be pinged.",
    }) catch {
        std.log.err("Error appending to alias list\n", .{});
        std.process.exit(1);
    };

    alias_list.append(allocator, Alias{
        .name = "alias-example-localhost",
        .mac = "00-00-00-00-00-00",
        .broadcast = "255.255.255.255",
        .port = 9,
        .fqdn = "localhost",
        .description = "Alias example. Can be pinged successfully when using the subcommand status. Does not support WOL.",
    }) catch {
        std.log.err("Error appending to alias list\n", .{});
        std.process.exit(1);
    };

    return alias_list;
}

/// Read the alias file in the same directory as the executable. Caller must free the memory after use.
/// Allocates internally.
pub fn readAliasFile(allocator: std.mem.Allocator, io: std.Io) ArrayList(Alias) {
    const file_path = getAliasFilePath(allocator, io);
    defer allocator.free(file_path);

    if (!aliasFileExists(allocator, io)) {
        std.log.info("Alias list file does not exist, creating the default file...\n", .{});
        const example_alias_list = getExampleAliasList(allocator);
        writeAliasFile(allocator, io, example_alias_list);
        return example_alias_list;
    }

    const file = std.Io.Dir.openFileAbsolute(io, file_path, .{ .mode = .read_only }) catch |err| {
        std.log.err("Error opening alias file: {}\n", .{err});
        std.process.exit(1);
    };
    defer file.close(io);

    const file_bytes = std.Io.Dir.readFileAlloc(.cwd(), io, file_path, allocator, .unlimited) catch |err| {
        std.log.err("Error opening alias file: {}\n", .{err});
        std.process.exit(1);
    };

    // Allocate a new null-terminated slice
    const file_source_nt = allocator.allocSentinel(u8, file_bytes.len, 0) catch |err| {
        std.log.err("Error allocating memory for alias file: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(file_source_nt);

    @memcpy(file_source_nt[0..file_bytes.len], file_bytes);

    // Zon parsing
    const alias_list_slice = std.zon.parse.fromSliceAlloc([]Alias, allocator, file_source_nt, null, .{}) catch |err| {
        std.log.err("Error parsing alias file: {}\n", .{err});
        std.process.exit(1);
    };

    // Create the alias list and fill with default items
    var alias_list = ArrayList(Alias).initCapacity(allocator, alias_list_slice.len) catch |err| {
        std.log.err("Error allocating memory for alias list: {}\n", .{err});
        std.process.exit(1);
    };

    for (alias_list_slice) |item| {
        alias_list.append(allocator, item) catch |err| {
            std.log.err("Error appending to alias list: {}\n", .{err});
            std.process.exit(1);
        };
    }

    return alias_list;
}

test "readAliasFile" {
    const page_allocator = std.heap.page_allocator;

    var alias_list = readAliasFile(page_allocator);
    defer alias_list.deinit(page_allocator);

    try std.testing.expect(alias_list.items.len >= 1);

    std.log.info("First alias: {s}, {s}, {s}\n", .{ alias_list.items[0].name, alias_list.items[0].mac, alias_list.items[0].description });

    try std.testing.expect(std.mem.eql(u8, alias_list.items[0].name, "alias-example-unreachable"));
    try std.testing.expect(std.mem.eql(u8, alias_list.items[0].mac, "01-01-01-ab-ab-ab"));
}

/// Write the alias file in the same directory as the executable. Overwrites if it already exists.
pub fn writeAliasFile(allocator: std.mem.Allocator, io: std.Io, alias_list: ArrayList(Alias)) void {
    const file_path = getAliasFilePath(allocator, io);
    defer allocator.free(file_path);

    const file = std.Io.Dir.createFileAbsolute(io, file_path, .{}) catch |err| {
        std.log.err("Error creating alias file: {}\n", .{err});
        std.process.exit(1);
    };
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.Writer.init(file, io, &buf);
    const writer_interface = &writer.interface;
    defer writer_interface.flush() catch |err| {
        std.log.err("Error flushing alias file: {}\n", .{err});
        std.process.exit(1);
    };

    std.zon.stringify.serialize(alias_list.items, .{}, writer_interface) catch |err| {
        std.log.err("Error serializing alias file: {}\n", .{err});
        std.process.exit(1);
    };
}

test "writeAliasFile" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const gpa = da.allocator();

    var alias_list = getExampleAliasList(gpa);
    defer alias_list.deinit(gpa);

    writeAliasFile(gpa, alias_list);
}

/// Computes the absolute path to the alias file in the same directory as the executable.
/// Caller must free the memory after use.
pub fn getAliasFilePath(allocator: std.mem.Allocator, io: std.Io) []u8 {
    const exe_dir_path = std.process.executableDirPathAlloc(io, allocator) catch |err| {
        std.log.err("Error getting self executable directory path: {}\n", .{err});
        std.process.exit(1);
    };

    const file_path = std.fs.path.join(allocator, &[_][]const u8{
        exe_dir_path,
        "alias.zon",
    }) catch |err| {
        std.log.err("Error joining paths: {}\n", .{err});
        std.process.exit(1);
    };

    return file_path;
}

test "getAliasFilePath" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const gpa = da.allocator();

    const file_path = getAliasFilePath(gpa);
    defer gpa.free(file_path);

    std.log.info("Alias file path: {s}\n", .{file_path});
}

/// Check if the zon alias file exists in the same directory as the executable.
/// Internally allocates and frees to compute the path.
pub fn aliasFileExists(allocator: std.mem.Allocator, io: std.Io) bool {
    const file_path = getAliasFilePath(allocator, io);
    defer allocator.free(file_path);

    _ = std.Io.Dir.accessAbsolute(io, file_path, .{ .read = true }) catch {
        return false;
    };

    return true;
}

test "aliasFileExists" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const gpa = da.allocator();

    _ = aliasFileExists(gpa);
}
