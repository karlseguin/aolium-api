const std = @import("std");
const httpz = @import("httpz");
const typed = @import("typed");
const zqlite = @import("zqlite");
const validate = @import("validate");
const auth = @import("_auth.zig");
const login = @import("login.zig");

const web = auth.web;
const wallz = web.wallz;
const User = wallz.User;

const argon2 = std.crypto.pwhash.argon2;
const ARGON_CONFIG = if (wallz.is_test) argon2.Params.fromLimits(1, 1024) else argon2.Params.interactive_2id;

var register_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	register_validator = builder.object(&.{
		builder.field("username", builder.string(.{.required = true, .trim = true, .min = 4, .max = wallz.MAX_USERNAME_LEN})),
		builder.field("password", builder.string(.{.required = true, .trim = true, .min = 6, .max = 70})),
	}, .{});
}

pub fn handler(env: *wallz.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateJson(req, register_validator, env);
	const username = input.get([]u8, "username").?;

	var pw_buf: [128]u8 = undefined;
	const hashed_password = try argon2.strHash(input.get([]u8, "password").?, .{
		.allocator = req.arena,
		.params = ARGON_CONFIG,
	}, &pw_buf);

	// load the user row
	const sql =
		\\ insert into users (username, password, active, reset_password)
		\\ values (?1, ?2, ?3, ?4)
	;
	const args = .{username, hashed_password, true, false};

	const app = env.app;
	const conn = app.getAuthConn();
	defer app.releaseAuthConn(conn);

	conn.exec(sql, args) catch |err| {
		if (!zqlite.isUnique(err)) {
			return wallz.sqliteErr("register.insert", err, conn, env.logger);
		}
		env._validator.?.addInvalidField(.{
			.field = "username",
			.err = "is already taken",
			.code = wallz.val.USERNAME_IN_USE,
		});
		return error.Validation;
	};

	return login.createSession(env, conn, .{
		.id = conn.lastInsertedRowId(),
		.username = username,
		.reset_password = false,
	}, res);
}

const t = wallz.testing;
test "auth.register: empty body" {
	var tc = t.context(.{});
	defer tc.deinit();
	try t.expectError(error.InvalidJson, handler(tc.env(), tc.web.req, tc.web.res));
}

test "auth.register: invalid json body" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.body("{hi");
	try t.expectError(error.InvalidJson, handler(tc.env(), tc.web.req, tc.web.res));
}

test "auth.register: invalid input" {
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

		tc.web.json(.{.username = "a2", .password = "12345"});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.STRING_LEN, .field = "username", .data = .{.min = 4, .max = 30}});
	try tc.expectInvalid(.{.code = validate.codes.STRING_LEN, .field = "password", .data = .{.min = 6, .max = 70}});
	}
}

test "auth.register: duplicate username" {
	var tc = t.context(.{});
	defer tc.deinit();

	_ = tc.insert.user(.{.username = "DupeUserTest"});

	tc.web.json(.{.username = "dupeusertest", .password = "1234567"});
	try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
	try tc.expectInvalid(.{.code = wallz.val.USERNAME_IN_USE, .field = "username"});
}

test "auth.register" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.json(.{.username = "reg-user", .password = "reg-passwrd"});
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(200);

	const body = (try tc.web.getJson()).object;
	const user_id = body.get("user").?.object.get("id").?.integer;
	const session_id = body.get("session_id").?.string;

	{
		const row = tc.getAuthRow("select password, active, reset_password, created from users where id = ?1", .{user_id}).?;
		try t.expectEqual(1, row.get(i64, "active").?);
		try t.expectEqual(0, row.get(i64, "reset_password").?);
		try t.expectDelta(std.time.timestamp(), row.get(i64, "created").?, 2);
		try argon2.strVerify(row.get([]u8, "password").?, "reg-passwrd", .{.allocator = tc.arena});
	}

	{
		const row = tc.getAuthRow("select user_id, expires from sessions where id = ?1", .{session_id}).?;
		try t.expectEqual(user_id, row.get(i64, "user_id").?);
		try t.expectDelta(std.time.timestamp() + 86_400, row.get(i64, "expires").?, 5);
	}
}
