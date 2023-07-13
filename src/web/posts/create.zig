const std = @import("std");
const httpz = @import("httpz");
const validate = @import("validate");
const posts = @import("_posts.zig");

const web = posts.web;
const pondz = web.pondz;

var create_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	create_validator = builder.object(&.{
		builder.field("title", builder.string(.{.max = 150, .trim = true})),
		builder.field("url", builder.string(.{.max = 200, .trim = true})),
		builder.field("content", builder.string(.{.max = 20_000, .trim = true})),
	}, .{});
}

pub fn handler(env: *pondz.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateJson(req, create_validator, env);

	const title = normalize(input.get([]u8, "title"));
	const content = normalize(input.get([]u8, "content"));
	const url = try normalizeURL(req.arena, input.get([]u8, "url"));

	if (content == null and url == null) {
		env._validator.?.addInvalidField(.{
			.field = null,
			.err = "either content or URL is required",
			.code = pondz.val.EMPTY_POST,
		});
		return error.Validation;
	}

	// dispatcher will make sure this is non-null
	const user = env.user.?;

	const sql = "insert into posts (user_id, title, url, content) values (?1, ?2, ?3, ?4)";
	const args = .{user.id, title, url, content};

	const app = env.app;
	const conn = app.getDataConn(user.shard_id);
	defer app.releaseDataConn(conn, user.shard_id);

	conn.exec(sql, args) catch |err| {
		return pondz.sqliteErr("posts.insert", err, conn, env.logger);
	};

	return res.json(.{
		.id = conn.lastInsertedRowId(),
	}, .{});
}

fn normalize(optional: ?[]const u8) ?[]const u8 {
	const value = optional orelse return null;
	return if (value.len == 0) null else value;
}

// we know allocator is an arena
fn normalizeURL(allocator: std.mem.Allocator, optional_url: ?[]const u8) !?[]const u8 {
	const url = optional_url orelse return null;
	if (url.len == 0) {
		return null;
	}

	const has_http_prefix = blk: {
		if (url.len < 8) {
			break :blk false;
		}
		if (std.ascii.startsWithIgnoreCase(url, "http") == false) {
			break :blk false;
		}
		if (url[4] == ':' and url[5] == '/' and url[6] == '/') {
			break :blk true;
		}

		break :blk (url[4] == 's' or url[4] == 'S') and url[5] == ':' and url[6] == '/' and url[7] == '/';
	};

	if (has_http_prefix) {
		return url;
	}

	var prefixed = try allocator.alloc(u8, url.len + 8);
	@memcpy(prefixed[0..8], "https://");
	@memcpy(prefixed[8..], url);
	return prefixed;
}

const t = pondz.testing;
test "posts normalizeURL" {
	try t.expectEqual(null, normalizeURL(undefined, null));
	try t.expectEqual(null, normalizeURL(undefined, ""));
	try t.expectString("http://pondz.dev", (try normalizeURL(undefined, "http://pondz.dev")).?);
	try t.expectString("HTTP://pondz.dev", (try normalizeURL(undefined, "HTTP://pondz.dev")).?);
	try t.expectString("https://www.openmymind.net", (try normalizeURL(undefined, "https://www.openmymind.net")).?);
	try t.expectString("HTTPS://www.openmymind.net", (try normalizeURL(undefined, "HTTPS://www.openmymind.net")).?);

	{
		const url = (try normalizeURL(t.allocator, "pondz.dev")).?;
		defer t.allocator.free(url);
		try t.expectString("https://pondz.dev", url);
	}
}

test "posts.create: empty body" {
	var tc = t.context(.{});
	defer tc.deinit();
	try t.expectError(error.InvalidJson, handler(tc.env(), tc.web.req, tc.web.res));
}

test "posts.create: invalid json body" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.body("{hi");
	try t.expectError(error.InvalidJson, handler(tc.env(), tc.web.req, tc.web.res));
}

test "posts.create: invalid input" {
	{
		var tc = t.context(.{});
		defer tc.deinit();

		tc.web.json(.{.x = 1});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = pondz.val.EMPTY_POST, .field = null});
	}

	{
		var tc = t.context(.{});
		defer tc.deinit();

		tc.web.json(.{.title = 32, .url = true, .content = .{.a = true}});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.TYPE_STRING, .field = "title"});
		try tc.expectInvalid(.{.code = validate.codes.TYPE_STRING, .field = "url"});
		try tc.expectInvalid(.{.code = validate.codes.TYPE_STRING, .field = "content"});
	}
}

test "posts.create" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 3913});
	tc.web.json(.{.title = "a title", .url = "pondz.dev", .content = "the content"});
	try handler(tc.env(), tc.web.req, tc.web.res);

	const body = (try tc.web.getJson()).object;
	const id = body.get("id").?.integer;

	const row = tc.getDataRow("select * from posts where id = ?1", .{id}).?;
	try t.expectEqual(3913, row.get(i64, "user_id").?);
	try t.expectString("a title", row.get([]u8, "title").?);
	try t.expectString("https://pondz.dev", row.get([]u8, "url").?);
	try t.expectString("the content", row.get([]u8, "content").?);
	try t.expectDelta(std.time.timestamp(), row.get(i64, "created").?, 2);
	try t.expectDelta(std.time.timestamp(), row.get(i64, "updated").?, 2);
}
