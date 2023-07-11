const std = @import("std");
const uuid = @import("uuid");
const logz = @import("logz");
const cache = @import("cache");
const httpz = @import("httpz");
const web = @import("web.zig");

const wallz = web.wallz;
const App = wallz.App;
const Env = wallz.Env;

// TODO: randomize on startup
var request_id: u32 = 0;

pub const Dispatcher = struct {
	app: *App,

	// whether or not to log HTTP request info (method, path, time, ...)
	log_http: bool = false,

	pub fn dispatch(self: *const Dispatcher, action: httpz.Action(*Env), req: *httpz.Request, res: *httpz.Response) !void {
		const start_time = std.time.microTimestamp();
		const app = self.app;

		const encoded_request_id = encodeRequestId(app.config.instance_id, @atomicRmw(u32, &request_id, .Add, 1, .Monotonic));

		// A multi-use logger. Any logs generated with it will contain the $rid attribute
		var logger = logz.logger().string("$rid", &encoded_request_id).multiuse();
		var env = Env{
			.app = app,
			.logger = logger,
		};
		defer env.deinit();

		var code: i32 = 0;
		action(&env, req, res) catch |err| switch (err) {
			error.Validation => {
				res.status = 400;
				try res.json(.{
					.err = "validation error",
					.code =  wallz.codes.VALIDATION_ERROR,
					.validation = env._validator.?.errors(),
				}, .{.emit_null_optional_fields = false});
				code = wallz.codes.VALIDATION_ERROR;
			},
			error.InvalidJson => {
				web.errors.InvalidJson.write(res);
				code = web.errors.InvalidJson.code;
			},
			else => {
				const error_id = try uuid.allocHex(res.arena);
				logger.
					err(err).
					level(.Error).
					ctx("http.err").
					stringSafe("eid", error_id).
					stringSafe("m", @tagName(req.method)).
					stringSafe("p", req.url.path).
					int("us", std.time.microTimestamp() - start_time).
					log();

				res.status = 500;
				res.header("Error-Id", error_id);
				return res.json(.{
					.error_id = error_id,
					.err = "internal server error",
					.code = wallz.codes.INTERNAL_SERVER_ERROR_CAUGHT,
				}, .{});
			}
		};

		if (self.log_http) {
		logger.
			stringSafe("@l", "REQ").
			int("s", res.status).
			stringSafe("m", @tagName(req.method)).
			stringSafe("p", req.url.path).
			int("code", code).
			int("us", std.time.microTimestamp() - start_time).
			log();
		}
	}
};

fn encodeRequestId(instance_id: u8, rid: u32) [8]u8 {
	const REQUEST_ID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
	const encoded_requested_id = std.mem.asBytes(&rid);

	var encoded: [8]u8 = undefined;
	encoded[7] = REQUEST_ID_ALPHABET[instance_id&0x1F];
	encoded[6] = REQUEST_ID_ALPHABET[(instance_id>>5|(encoded_requested_id[0]<<3))&0x1F];
	encoded[5] = REQUEST_ID_ALPHABET[(encoded_requested_id[0]>>2)&0x1F];
	encoded[4] = REQUEST_ID_ALPHABET[(encoded_requested_id[0]>>7|(encoded_requested_id[1]<<1))&0x1F];
	encoded[3] = REQUEST_ID_ALPHABET[((encoded_requested_id[1]>>4)|(encoded_requested_id[2]<<4))&0x1F];
	encoded[2] = REQUEST_ID_ALPHABET[(encoded_requested_id[2]>>1)&0x1F];
	encoded[1] = REQUEST_ID_ALPHABET[((encoded_requested_id[2]>>6)|(encoded_requested_id[3]<<2))&0x1F];
	encoded[0] = REQUEST_ID_ALPHABET[encoded_requested_id[3]>>3];
	return encoded;
}

const t = wallz.testing;
test "dispatcher: encodeRequestId" {
	try t.expectString("AAAAAAYA", &encodeRequestId(0, 3));
	try t.expectString("AAAAABAA", &encodeRequestId(0, 4));
	try t.expectString("AAAAAAYC", &encodeRequestId(2, 3));
	try t.expectString("AAAAABAC", &encodeRequestId(2, 4));
}

test "dispatcher: handles action error" {
	var tc = t.context(.{});
	defer tc.deinit();

	t.noLogs();
	defer t.restoreLogs();

	const dispatcher = Dispatcher{.app = tc.app};
	try dispatcher.dispatch(testErrorAction, tc.web.req, tc.web.res);
	try tc.web.expectStatus(500);
	try tc.web.expectJson(.{.code = 1});
}

test "dispatcher: handles action validation error" {
	var tc = t.context(.{});
	defer tc.deinit();

	const dispatcher = Dispatcher{.app = tc.app};
	try dispatcher.dispatch(testValidationAction, tc.web.req, tc.web.res);
	try tc.web.expectStatus(400);
	try tc.web.expectJson(.{.code = 5, .validation = &.{.{.code = 322, .err = "i cannot do that"}}});
}

test "dispatcher: handles action invalidJson error" {
	var tc = t.context(.{});
	defer tc.deinit();

	const dispatcher = Dispatcher{.app = tc.app};
	try dispatcher.dispatch(testInvalidJson, tc.web.req, tc.web.res);
	try tc.web.expectStatus(400);
	try tc.web.expectJson(.{.code = 4, .err = "invalid JSON"});
}

test "dispatcher: dispatch to actions" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.url("/test_1");

	request_id = 958589;
	const dispatcher = Dispatcher{.app = tc.app};
	try dispatcher.dispatch(callableAction, tc.web.req, tc.web.res);
	try tc.web.expectStatus(200);
	try tc.web.expectJson(.{.url = "/test_1"});
}

fn testErrorAction(_: *Env, _: *httpz.Request, _: *httpz.Response) !void {
	return error.Nope;
}

fn testValidationAction(env: *Env, _: *httpz.Request, _: *httpz.Response) !void {
	var validator = try env.validator();
	try validator.add(.{.code = 322, .err = "i cannot do that"});
	return error.Validation;
}

fn testInvalidJson( _: *Env, _: *httpz.Request, _: *httpz.Response) !void {
	return error.InvalidJson;
}

fn callableAction(env: *Env, req: *httpz.Request, res: *httpz.Response) !void {
	var arr = std.ArrayList(u8).init(t.allocator);
	defer arr.deinit();

	if (std.mem.eql(u8, req.url.path, "/test_1")) {
		try env.logger.logTo(arr.writer());
		try t.expectString("@ts=9999999999999 $rid=AAHKA7IA\n", arr.items);
	} else {
		unreachable;
	}
	return res.json(.{.url = req.url.path}, .{});
}
