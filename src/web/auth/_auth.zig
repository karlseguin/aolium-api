const validate = @import("validate");
pub const web = @import("../web.zig");

// expose nested routes
pub const _check = @import("check.zig");
pub const _login = @import("login.zig");
pub const _logout = @import("logout.zig");
pub const _register = @import("register.zig");

pub const check = _check.handler;
pub const login = _login.handler;
pub const logout = _logout.handler;
pub const register = _register.handler;

pub fn init(builder: *validate.Builder(void)) !void {
	_login.init(builder);
	_register.init(builder);
}
