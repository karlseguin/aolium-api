pub const User = struct {
	id: i64,

	pub fn init(id: i64) User {
		return .{.id = id};
	}
};
