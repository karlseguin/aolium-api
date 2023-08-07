pub const App = @import("app.zig").App;
pub const Env = @import("env.zig").Env;
pub const User = @import("user.zig").User;
pub const Config = @import("config.zig").Config;

pub const is_test = @import("builtin").is_test;
pub var version: []const u8 = @embedFile("version.txt");
pub const MAX_USERNAME_LEN = 20;

// +37 = /UUID
pub const MAX_WEB_POST_URL = "https://www.aolium.com/".len + MAX_USERNAME_LEN + 37;

pub const codes = struct {
	pub const INTERNAL_SERVER_ERROR_UNCAUGHT = 0;
	pub const INTERNAL_SERVER_ERROR_CAUGHT = 1;
	pub const ROUTER_NOT_FOUND = 2;
	pub const NOT_FOUND = 3;
	pub const INVALID_JSON = 4;
	pub const VALIDATION_ERROR = 5;
	pub const INVALID_AUTHORIZATION = 6;
	pub const EXPIRED_SESSION_ID = 7;
	pub const ACCESS_DENIED = 8;
	pub const CONNECTION_RESET = 9;
};

pub const val = struct {
	pub const USERNAME_IN_USE = 100;
	pub const EMPTY_POST = 101;
	pub const INVALID_EMAIL = 102;
	pub const INVALID_USERNAME = 103;
	pub const RESERVED_USERNAME = 104;
	pub const UNKNOWN_USERNAME = 105;
};

pub const testing = @import("t.zig");

const logz = @import("logz");
pub fn sqliteErr(ctx: []const u8, err: anyerror, conn: anytype, logger: logz.Logger) error{SqliteError} {
	logger.level(.Error).
		ctx(ctx).
		err(err).
		boolean("sqlite", true).
		stringZ("desc", conn.lastError()).
		log();

	return error.SqliteError;
}
