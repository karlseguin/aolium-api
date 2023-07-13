const pondz = @import("pondz.zig");
const App = pondz.App;

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
