const validate = @import("validate");
pub const web = @import("../web.zig");

// expose nested routes
pub const _create = @import("create.zig");

pub const create = _create.handler;

pub fn init(builder: *validate.Builder(void)) !void {
	_create.init(builder);
}
