const std = @import("std");
const httpz = @import("httpz");
const typed = @import("typed");
const validate = @import("validate");
const auth = @import("_auth.zig");

const web = auth.web;
const wallz = web.wallz;
const argon2 = std.crypto.pwhash.argon2;

var login_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	login_validator = builder.object(&.{
		builder.field("username", builder.string(.{.required = true, .min = 1})),
		builder.field("password", builder.string(.{.required = true, .min = 1})),
	}, .{});
}

pub fn handler(env: *wallz.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateJson(req, login_validator, env);
	_ = input;
	_ = res;
}

const t = wallz.testing;
test "auth.login empty body" {
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
