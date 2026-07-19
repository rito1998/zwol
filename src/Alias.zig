const Alias = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

name: []const u8,
mac: []const u8,
broadcast: []const u8,
fqdn: []const u8,

pub fn free(self: *const Alias, allocator: Allocator) void {
    allocator.free(self.name);
    allocator.free(self.mac);
    allocator.free(self.broadcast);
    allocator.free(self.fqdn);
}

pub fn clone(self: *const Alias, allocator: Allocator) !Alias {
    const name = try allocator.dupe(u8, self.name);
    errdefer allocator.free(name);

    const mac = try allocator.dupe(u8, self.mac);
    errdefer allocator.free(mac);

    const broadcast = try allocator.dupe(u8, self.broadcast);
    errdefer allocator.free(broadcast);

    const fqdn = try allocator.dupe(u8, self.fqdn);
    errdefer allocator.free(fqdn);

    return .{
        .name = name,
        .mac = mac,
        .broadcast = broadcast,
        .fqdn = fqdn,
    };
}
