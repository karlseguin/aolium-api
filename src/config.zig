const logz = @import("logz");
const httpz = @import("httpz");
const pondz = @import("pondz.zig");
const validate = @import("validate");

pub const Config = struct {
	// The absolute root DB path
	root: [:0]const u8,

	// For improving the uniqueness of request_id in a multi-server setup
	// The instance_id is part of the request_id, thus N instances will generate
	// distinct request_ids from each other
	instance_id: u8,

	// http port to listen on
	port: u16,

	// address to bind to
	address: []const u8,

	// https://github.com/ziglang/zig/issues/15091
	log_http: bool,

	cors: ?httpz.Config.CORS = null,
	logger: logz.Config = .{},
	validator: validate.Config = .{},
};
