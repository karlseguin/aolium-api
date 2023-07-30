const std = @import("std");
const aolium = @import("aolium.zig");

const App = aolium.App;
const Allocator = std.mem.Allocator;

pub const User = struct {
	id: i64,
	shard_id: usize,
	username: []const u8,

	pub fn init(allocator: Allocator, id: i64, username: []const u8) !User {
		return .{
			.id = id,
			.shard_id = App.getShardId(username),
			.username = try allocator.dupe(u8, username),
		};
	}

	pub fn removedFromCache(self: User, allocator: Allocator) void {
		allocator.free(self.username);
	}
};
