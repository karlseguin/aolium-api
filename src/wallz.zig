pub const App = @import("app.zig").App;
pub const Env = @import("env.zig").Env;
pub const Config = @import("config.zig").Config;

pub const is_test = @import("builtin").is_test;
pub var version: []const u8 = @embedFile("version.txt");

pub const codes = struct {
	pub const INTERNAL_SERVER_ERROR_UNCAUGHT = 0;
	pub const INTERNAL_SERVER_ERROR_CAUGHT = 1;
	pub const ROUTER_NOT_FOUND = 2;
	pub const NOT_FOUND = 3;
	pub const INVALID_JSON = 4;
	pub const VALIDATION_ERROR = 5;
};

pub const testing = @import("t.zig");
