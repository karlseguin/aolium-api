const std = @import("std");
const httpz = @import("httpz");
const typed = @import("typed");
const zqlite = @import("zqlite");
const validate = @import("validate");
const auth = @import("_auth.zig");

const web = auth.web;
const aolium = web.aolium;
const argon2 = std.crypto.pwhash.argon2;

const User = aolium.User;

var login_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	login_validator = builder.object(&.{
		builder.field("username", builder.string(.{.required = true, .trim = true, .min = 1})),
		builder.field("password", builder.string(.{.required = true, .trim = true, .min = 1})),
	}, .{});
}

pub fn handler(env: *aolium.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateJson(req, login_validator, env);
	const username = input.get([]u8, "username").?;

	// load the user row
	const sql =
		\\ select id, password, reset_password
		\\ from users
		\\ where lower(username) = lower(?1) and active
	;
	const args = .{username};

	const app = env.app;
	const conn = app.getAuthConn();
	defer app.releaseAuthConn(conn);

	const row = conn.row(sql, args) catch |err| {
		return aolium.sqliteErr("login.select", err, conn, env.logger);
	} orelse {
		// timing attack, username enumeration it's security theater here.
		return web.notFound(res, "username or password are invalid");
	};
	defer row.deinit();

	{
		// verify the password
		const hashed = row.text(1);
		argon2.strVerify(hashed, input.get([]u8, "password").?, .{.allocator = req.arena}) catch {
			return web.notFound(res, "username or password are invalid");
		};
	}

	return createSession(env, conn, .{
		.id = row.int(0),
		.username = username,
		.reset_password = row.int(2) == 1,
	}, res);
}

// used by register.zig
pub fn createSession(env: *aolium.Env, conn: zqlite.Conn, user_data: anytype, res: *httpz.Response) !void {
	const user_id = user_data.id;

	var session_id_buf: [20]u8 = undefined;
	std.crypto.random.bytes(&session_id_buf);
	const session_id = std.fmt.bytesToHex(session_id_buf, .lower);

	{
		// create the session
		const session_sql = "insert into sessions (id, user_id, expires) values (?1, ?2, unixepoch() + 2592000)";
		conn.exec(session_sql,.{&session_id, user_id}) catch |err| {
			return aolium.sqliteErr("sessions.insert", err, conn, env.logger);
		};
	}

	const user = User.init(user_id, user_data.username);
	try env.app.session_cache.put(&session_id, user, .{.ttl = 1800});

	return res.json(.{
		.user = .{
			.id = user.id,
			.username = user_data.username,
		},
		.session_id = session_id,
		.reset_password = user_data.reset_password,
	}, .{});
}

const t = aolium.testing;
test "auth.login: empty body" {
	var tc = t.context(.{});
	defer tc.deinit();
	try t.expectError(error.InvalidJson, handler(tc.env(), tc.web.req, tc.web.res));
}

test "auth.login: invalid json body" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.body("{hi");
	try t.expectError(error.InvalidJson, handler(tc.env(), tc.web.req, tc.web.res));
}

test "auth.login: invalid input" {
	{
		var tc = t.context(.{});
		defer tc.deinit();

		tc.web.json(.{.hack = true});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "username"});
		try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "password"});
	}

	{
		var tc = t.context(.{});
		defer tc.deinit();

		tc.web.json(.{.username = 32, .password = true});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.TYPE_STRING, .field = "username"});
		try tc.expectInvalid(.{.code = validate.codes.TYPE_STRING, .field = "password"});
	}
}

test "auth.login: username not found" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.json(.{.username = "piter", .password = "sapho"});
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);
	try tc.web.expectJson(.{.desc = "username or password are invalid", .code = 3});
}

test "auth.login: not active" {
	var tc = t.context(.{});
	defer tc.deinit();

	_ = tc.insert.user(.{.active = false, .username = "duncan", .password = "ginaz"});
	tc.web.json(.{.username = "duncan", .password = "ginaz"});
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);
	try tc.web.expectJson(.{.desc = "username or password are invalid", .code = 3});
}

test "auth.login" {
	var tc = t.context(.{});
	defer tc.deinit();

	const user_id1 = tc.insert.user(.{.username = "leto", .password = "ghanima"});
	const user_id2 = tc.insert.user(.{.username = "Paul", .password = "chani", .reset_password = true});

	{
		// wrong password
		tc.web.json(.{.username = "leto", .password = "paul"});
		try handler(tc.env(), tc.web.req, tc.web.res);
		try tc.web.expectStatus(404);
		try tc.web.expectJson(.{.desc = "username or password are invalid", .code = 3});
	}

	{
		// valid
		tc.reset();
		tc.web.json(.{.username = "leto", .password = "ghanima"});
		try handler(tc.env(), tc.web.req, tc.web.res);
		try tc.web.expectStatus(200);
		try tc.web.expectJson(.{.user = .{.id = user_id1, .username = "leto"}, .reset_password = false});

		const body = (try tc.web.getJson()).object;
		const session_id = body.get("session_id").?.string;

		const row = tc.getAuthRow("select user_id, expires from sessions where id = ?1", .{session_id}).?;
		try t.expectEqual(user_id1, row.get(i64, "user_id").?);
		try t.expectDelta(std.time.timestamp() + 86_400, row.get(i64, "expires").?, 5);
	}

	{
		// valid, different user, with reset_password
		tc.reset();
		tc.web.json(.{.username = "PAUL", .password = "chani"});
		try handler(tc.env(), tc.web.req, tc.web.res);
		try tc.web.expectStatus(200);
		try tc.web.expectJson(.{.user = .{.id = user_id2, .username = "PAUL"}, .reset_password = true});

		const body = (try tc.web.getJson()).object;
		const session_id = body.get("session_id").?.string;

		const row = tc.getAuthRow("select user_id, expires from sessions where id = ?1", .{session_id}).?;
		try t.expectEqual(user_id2, row.get(i64, "user_id").?);
		try t.expectDelta(std.time.timestamp() + 86_400, row.get(i64, "expires").?, 5);
	}
}
