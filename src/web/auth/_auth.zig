const validate = @import("validate");
pub const web = @import("../web.zig");

// expose nested routes
pub const _login = @import("login.zig");

pub const login = _login.handler;

pub fn init(builder: *validate.Builder(void)) !void {
	_login.init(builder);
}
