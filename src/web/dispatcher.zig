const std = @import("std");
const uuid = @import("uuid");
const logz = @import("logz");
const cache = @import("cache");
const httpz = @import("httpz");
const web = @import("web.zig");

const pondz = web.pondz;
const App = pondz.App;
const Env = pondz.Env;
const User = pondz.User;

// TODO: randomize on startup
var request_id: u32 = 0;

pub const Dispatcher = struct {
	app: *App,

	// whether to try loading the user or not, this implies requires_user = false
	load_user: bool = true,

	// whether a user is required. When false, if we have a token, the user is still
	// loaded (unless load_user = false).
	requires_user: bool = false,

	// whether or not to log HTTP request info (method, path, time, ...)
	log_http: bool = false,

	pub fn dispatch(self: *const Dispatcher, action: httpz.Action(*Env), req: *httpz.Request, res: *httpz.Response) !void {
		const start_time = std.time.milliTimestamp();

		const app = self.app;
		const encoded_request_id = encodeRequestId(app.config.instance_id, @atomicRmw(u32, &request_id, .Add, 1, .Monotonic));
		var logger = logz.logger().stringSafe("$rid", &encoded_request_id).multiuse();

		var env = Env{
			.app = app,
			.logger = logger,
		};
		defer env.deinit();

		var code: i32 = 0;
		var log_request = self.log_http;

		self.doDispatch(action, req, res, &env) catch |err| switch (err) {
			error.InvalidAuthorization => code = web.errors.InvalidAuthorization.write(res),
			error.ExpiredSessionId => code = web.errors.ExpiredSessionId.write(res),
			error.InvalidJson => code = web.errors.InvalidJson.write(res),
			error.UserRequired => code = web.errors.AccessDenied.write(res),
			error.Validation => {
				code = pondz.codes.VALIDATION_ERROR;
				res.status = 400;
				try res.json(.{
					.err = "validation error",
					.code = code,
					.validation = env._validator.?.errors(),
				}, .{.emit_null_optional_fields = false});
			},
			else => {
				code = pondz.codes.INTERNAL_SERVER_ERROR_CAUGHT;
				const error_id = try uuid.allocHex(res.arena);

				res.status = 500;
				res.header("Error-Id", error_id);
				try res.json(.{
					.code = code,
					.error_id = error_id,
					.err = "internal server error",
				}, .{});

				log_request = true;
				_ = logger.stringSafe("error_id", error_id).err(err);
			},
		};

		if (log_request) {
			logger.
				stringSafe("@l", "REQ").
				stringSafe("method", @tagName(req.method)).
				string("path", req.url.path).
				int("status", res.status).
				int("code", code).
				int("uid", if (env.user) |u| u.id else 0).
				int("ms", std.time.milliTimestamp() - start_time).
				log();
		}
	}

	fn doDispatch(self: *const Dispatcher, action: httpz.Action(*Env), req: *httpz.Request, res: *httpz.Response, env: *Env) !void {
		if (self.load_user) {
			const user_entry = try loadUser(env.app, web.getSessionId(req));
			env._cached_user_entry = user_entry;

			if (user_entry) |ue| {
				env.user = ue.value;
			} else if (self.requires_user) {
				return error.UserRequired;
			}
		}

		try action(env, req, res);
	}
};

fn loadUser(app: *App, optional_session_id: ?[]const u8) !?*cache.Entry(User) {
	const session_id = optional_session_id orelse return null;
	if (try app.session_cache.fetch(*App, session_id, loadUserFromSessionId, app, .{.ttl = 1800})) |entry| {
		return entry;
	}
	return error.InvalidAuthorization;
}

fn loadUserFromSessionId(app: *App, session_id: []const u8) !?User {
	const sql =
		\\ select s.user_id, s.expires, u.username
		\\ from sessions s join users u on s.user_id = u.id
		\\ where u.active and s.id = $1
	;
	const args = .{session_id};

	const conn = app.getAuthConn();
	defer app.releaseAuthConn(conn);

	const row = conn.row(sql, args) catch |err| {
		return pondz.sqliteErr("Dispatcher.loadUser", err, conn, logz.logger());
	} orelse return null;
	defer row.deinit();

	if (row.int(1) < std.time.timestamp()) {
		return error.ExpiredSessionId;
	}

	return User.init(row.int(0), row.text(2));
}

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

const t = pondz.testing;
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

test "dispatcher: load user" {
	var tc = t.context(.{});
	defer tc.deinit();

	const user_id1 = tc.insert.user(.{});

	var dispatcher = Dispatcher{.app = tc.app};

	{
		// no authorization header on public route, no problem
		try dispatcher.dispatch(testEchoUser, tc.web.req, tc.web.res);
		try tc.web.expectStatus(200);
		try tc.web.expectJson(.{.is_null = true});
	}

	{
		tc.reset();
		// no authorization header on non-public route,  problem
		const d = Dispatcher{.app = tc.app, .requires_user = true};
		try d.dispatch(testErrorAction, tc.web.req, tc.web.res);
		try tc.web.expectStatus(401);
		try tc.web.expectJson(.{.code = 8});
	}

	{
		// unknown token
		tc.reset();
		tc.web.header("authorization", "pondz abc12345558");
		try dispatcher.dispatch(testErrorAction, tc.web.req, tc.web.res);
		try tc.web.expectStatus(401);
		try tc.web.expectJson(.{.code = 6});
	}

	{
		// expired token
		tc.reset();
		const sid = tc.insert.session(.{.user_id = user_id1, .ttl = - 1});
		tc.web.header("authorization", try std.fmt.allocPrint(tc.arena, "pondz {s}", .{sid}));
		try dispatcher.dispatch(testErrorAction, tc.web.req, tc.web.res);
		try tc.web.expectStatus(401);
		try tc.web.expectJson(.{.code = 7});
	}

	{
		// valid token
		tc.reset();
		const sid = tc.insert.session(.{.user_id = user_id1, .ttl = 2});
		tc.web.header("authorization", try std.fmt.allocPrint(tc.arena, "pondz {s}", .{sid}));
		try dispatcher.dispatch(testEchoUser, tc.web.req, tc.web.res);
		try tc.web.expectJson(.{.id = user_id1});
	}
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

fn testEchoUser(env: *Env, _: *httpz.Request, res: *httpz.Response) !void {
	const user = env.user orelse {
		return res.json(.{.is_null = true}, .{});
	};

	return res.json(.{.id = user.id}, .{});
}
