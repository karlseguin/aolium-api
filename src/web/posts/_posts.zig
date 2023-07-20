const validate = @import("validate");
pub const web = @import("../web.zig");

// expose nested routes
pub const _index = @import("index.zig");
pub const _create = @import("create.zig");

pub const index = _index.handler;
pub const create = _create.handler;

pub fn init(builder: *validate.Builder(void)) !void {
	_index.init(builder);
	_create.init(builder);
}
