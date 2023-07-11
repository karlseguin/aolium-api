const std = @import("std");
const logz = @import("logz");
const wallz = @import("wallz.zig");

const Allocator = std.mem.Allocator;
const argon2 = std.crypto.pwhash.argon2;

const ARGON_CONFIG = if (wallz.is_test) argon2.Params.fromLimits(1, 1024) else argon2.Params.interactive_2id;

pub const User = struct {
	id: []const u8,

	pub fn init(allocator: Allocator, id: []const u8) !User {
		return .{
			.id = try allocator.dupe(u8, id),
		};
	}

	fn deinit(self: User, allocator: Allocator) void {
		allocator.free(self.id);
	}

	pub fn removedFromCache(self: User, allocator: Allocator) void {
		self.deinit(allocator);
	}
};
