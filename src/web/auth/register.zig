const std = @import("std");
const httpz = @import("httpz");
const typed = @import("typed");
const zqlite = @import("zqlite");
const validate = @import("validate");
const auth = @import("_auth.zig");
const login = @import("login.zig");

const web = auth.web;
const pondz = web.pondz;
const User = pondz.User;

const argon2 = std.crypto.pwhash.argon2;
const ARGON_CONFIG = if (pondz.is_test) argon2.Params.fromLimits(1, 1024) else argon2.Params.interactive_2id;

var register_validator: *validate.Object(void) = undefined;

const reserved_usernames = [_][]const u8 {
	"about",
	"account",
	"accounts",
	"admin",
	"auth",
	"blog",
	"contact",
	"feedback",
	"home",
	"info",
	"karl" // on no he didn't
	"login",
	"logout",
	"news",
	"pond",
	"pondz",
	"privacy",
	"settings",
	"site",
	"status",
	"support",
	"terms",
	"user",
	"users",
};

pub fn init(builder: *validate.Builder(void)) void {
	register_validator = builder.object(&.{
		builder.field("username", builder.string(.{.required = true, .trim = true, .min = 4, .max = pondz.MAX_USERNAME_LEN, .function = validateUsername})),
		builder.field("password", builder.string(.{.required = true, .trim = true, .min = 6, .max = 70})),
		builder.field("email", builder.string(.{.trim = true, .function = validateEmail, .max = 100})),
	}, .{});
}

pub fn handler(env: *pondz.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateJson(req, register_validator, env);
	const username = input.get([]u8, "username").?;

	var pw_buf: [128]u8 = undefined;
	const hashed_password = try argon2.strHash(input.get([]u8, "password").?, .{
		.allocator = req.arena,
		.params = ARGON_CONFIG,
	}, &pw_buf);

	var hashed_email: ?[]const u8 = null;
	if (input.get([]u8, "email")) |email| {
		var email_buf: [128]u8 = undefined;
		hashed_email = try argon2.strHash(email, .{
			.allocator = req.arena,
			.params = ARGON_CONFIG,
		}, &email_buf);
	}

	// load the user row
	const sql =
		\\ insert into users (username, password, email, active, reset_password)
		\\ values (?1, ?2, ?3, ?4, ?5)
	;
	const args = .{username, hashed_password, hashed_email, true, false};

	const app = env.app;
	const conn = app.getAuthConn();
	defer app.releaseAuthConn(conn);

	conn.exec(sql, args) catch |err| {
		if (!zqlite.isUnique(err)) {
			return pondz.sqliteErr("register.insert", err, conn, env.logger);
		}
		env._validator.?.addInvalidField(.{
			.field = "username",
			.err = "is already taken",
			.code = pondz.val.USERNAME_IN_USE,
		});
		return error.Validation;
	};

	return login.createSession(env, conn, .{
		.id = conn.lastInsertedRowId(),
		.username = username,
		.reset_password = false,
	}, res);
}

fn validateEmail(value: ?[]const u8, context: *validate.Context(void)) !?[]const u8 {
	// we're ok with a null email, because we're cool
	const email = value orelse return null;

	// IMO, \S+@\S+\.\S+ is the best email regex, but I don't want to pull
	// in a regex library just for this, and we can more or less do something similar.

	var valid = true;
	var at: ?usize = null;
	var dot: ?usize = null;
	for (email, 0..) |c, i| {
		if (c == '.') {
			dot = i;
		} else if (c == '@') {
			if (at != null) {
				valid = false;
				break;
			}
			at = i;
		} else if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
			valid = false;
			break;
		}
	}

	const at_index = at orelse blk: {
		valid = false;
		break :blk 0;
	};

	const dot_index = dot orelse blk: {
		valid = false;
		break :blk 0;
	};

	if (!valid or at_index == 0 or dot_index == email.len - 1) {
		try context.add(validate.Invalid{
			.code = pondz.val.INVALID_EMAIL,
			.err = "is not valid",
		});
	}

	return email;
}

fn validateUsername(value: ?[]const u8, context: *validate.Context(void)) !?[]const u8 {
	const username = value.?;
	var valid = std.ascii.isAlphabetic(username[0]);

	if (valid) {
		for (username[1..]) |c| {
			if (std.ascii.isAlphanumeric(c)) {
				continue;
			}
			if (c == '_' or c == '.' or c == '-') {
				continue;
			}
			valid = false;
			break;
		}
	}

	if (valid == false) {
		try context.add(validate.Invalid{
			.code = pondz.val.INVALID_USERNAME,
			.err = "must begin with a letter, and only contain letters, numbers, unerscore, dot or hyphen",
		});
	}

	if (std.sort.binarySearch([]const u8, username, &reserved_usernames, {}, compareString) != null) {
		try context.add(validate.Invalid{
			.code = pondz.val.RESERVED_USERNAME,
			.err = "is reserved",
		});
	}

	return username;
}

fn compareString(_: void, key: []const u8, value: []const u8) std.math.Order {
	var key_compare = key;
	var value_compare = value;

	var result = std.math.Order.eq;

	if (value.len < key.len) {
		result = std.math.Order.gt;
		key_compare = key[0..value.len];
	} else if (value.len > key.len) {
		result = std.math.Order.lt;
		value_compare = value[0..key.len];
	}

	for (key_compare, value_compare) |k, v| {
		var order = std.math.order(std.ascii.toLower(k), v);
		if (order != .eq) {
			return order;
		}
	}

	return result;
}

const t = pondz.testing;
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

		tc.web.json(.{.hack = true, .email = "nope"});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "username"});
		try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "password"});
		try tc.expectInvalid(.{.code = pondz.val.INVALID_EMAIL, .field = "email"});
	}

	{
		var tc = t.context(.{});
		defer tc.deinit();

		tc.web.json(.{.username = "a2", .password = "12345"});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.STRING_LEN, .field = "username", .data = .{.min = 4, .max = 20}});
	try tc.expectInvalid(.{.code = validate.codes.STRING_LEN, .field = "password", .data = .{.min = 6, .max = 70}});
	}
}

test "auth.register: duplicate username" {
	var tc = t.context(.{});
	defer tc.deinit();

	_ = tc.insert.user(.{.username = "DupeUserTest"});

	tc.web.json(.{.username = "dupeusertest", .password = "1234567"});
	try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
	try tc.expectInvalid(.{.code = pondz.val.USERNAME_IN_USE, .field = "username"});
}

test "auth.register: success no email" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.json(.{.username = "reg-user", .password = "reg-passwrd"});
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(200);

	const body = (try tc.web.getJson()).object;
	const user_id = body.get("user").?.object.get("id").?.integer;
	const session_id = body.get("session_id").?.string;

	{
		const row = tc.getAuthRow("select password, active, reset_password, email, created from users where id = ?1", .{user_id}).?;
		try t.expectEqual(1, row.get(i64, "active").?);
		try t.expectEqual(0, row.get(i64, "reset_password").?);
		try t.expectEqual(null, row.get([]u8, "email"));
		try t.expectDelta(std.time.timestamp(), row.get(i64, "created").?, 2);
		try argon2.strVerify(row.get([]u8, "password").?, "reg-passwrd", .{.allocator = tc.arena});
	}

	{
		const row = tc.getAuthRow("select user_id, expires from sessions where id = ?1", .{session_id}).?;
		try t.expectEqual(user_id, row.get(i64, "user_id").?);
		try t.expectDelta(std.time.timestamp() + 86_400, row.get(i64, "expires").?, 5);
	}
}

test "auth.register: success with email" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.json(.{.username = "reg-user2", .password = "reg-passwrd2", .email = "leto@pondz.dev"});
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(200);

	const row = tc.getAuthRow("select email from users where username = 'reg-user2'", .{}).?;
	try argon2.strVerify(row.get([]u8, "email").?, "leto@pondz.dev", .{.allocator = tc.arena});
}

test "auth.validateEmail" {
	var tc = t.context(.{});
	defer tc.deinit();

	const validator = try tc.app.validators.acquire({});

	try t.expectEqual(null, try validateEmail(null, validator));
	try t.expectString("leto@caladan.gov", (try validateEmail("leto@caladan.gov", validator)).?);
	try t.expectString("a@b.gov.museum", (try validateEmail("a@b.gov.museum", validator)).?);

	const invalid_emails = [_][]const u8{
		"nope",
		"has @aspace.com",
		"has@two@ats.com",
		"@test.com",
		"leto@test.",
	};

	for (invalid_emails) |email| {
		validator.reset();
		_ = try validateEmail(email, validator);
		try validate.testing.expectInvalid(.{.code = pondz.val.INVALID_EMAIL}, validator);
	}
}

test "auth.validateUsername" {
	var tc = t.context(.{});
	defer tc.deinit();

	const validator = try tc.app.validators.acquire({});

	try t.expectString("leto", (try validateUsername("leto", validator)).?);
	try t.expectString("l.e_t-0", (try validateUsername("l.e_t-0", validator)).?);

	{
		const invalid_usernames = [_][]const u8{
			"1eto",
			"_eto",
			"l eto",
			"l$eto",
			"l!te",
			"l@eto",
		};

		for (invalid_usernames) |username| {
			validator.reset();
			_ = try validateUsername(username, validator);
			try validate.testing.expectInvalid(.{.code = pondz.val.INVALID_USERNAME}, validator);
		}
	}

	{
		var buf: [20]u8 = undefined;
		for (reserved_usernames) |reserved| {
			validator.reset();
			_ = try validateUsername(reserved, validator);
			try validate.testing.expectInvalid(.{.code = pondz.val.RESERVED_USERNAME}, validator);

			// also test the uppercase version
			validator.reset();
			const upper = std.ascii.upperString(&buf, reserved);
			_ = try validateUsername(upper, validator);
			try validate.testing.expectInvalid(.{.code = pondz.val.RESERVED_USERNAME}, validator);
		}
	}
}
