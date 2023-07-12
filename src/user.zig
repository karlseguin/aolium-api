const wallz = @import("wallz.zig");
const App = wallz.App;

pub const User = struct {
	id: i64,
	shard_id: usize,

	pub fn init(id: i64, username: []const u8) User {
		return .{
			.id = id,
			.shard_id = App.getShardId(username),
		};
	}
};
