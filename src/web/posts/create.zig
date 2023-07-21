const std = @import("std");
const uuid = @import("uuid");
const httpz = @import("httpz");
const validate = @import("validate");
const posts = @import("_posts.zig");

const web = posts.web;
const pondz = web.pondz;

pub fn handler(env: *pondz.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateJson(req, posts.create_validator, env);
	const post = try posts.Post.create(req.arena, input);

	const user = env.user.?;
	const post_id = uuid.bin();
	const sql = "insert into posts (id, user_id, title, text, type) values (?1, ?2, ?3, ?4, ?5)";
	const args = .{&post_id, user.id, post.title, post.text, post.type};

	const app = env.app;

	{
		// we want conn released ASAP
		const conn = app.getDataConn(user.shard_id);
		defer app.releaseDataConn(conn, user.shard_id);

		conn.exec(sql, args) catch |err| {
			return pondz.sqliteErr("posts.insert", err, conn, env.logger);
		};
	}

	app.clearUserCache(user.id);

	var hex_uuid: [36]u8 = undefined;
	return res.json(.{
		.id = uuid.toString(&post_id, &hex_uuid),
	}, .{});
}

const t = pondz.testing;
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
		try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "type"});
	}

	{
		var tc = t.context(.{});
		defer tc.deinit();

		tc.web.json(.{.type = "melange"});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.STRING_CHOICE, .field = "type"});
	}

	{
		var tc = t.context(.{});
		defer tc.deinit();

		tc.web.json(.{.type = "simple"});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "text"});
	}

	{
		var tc = t.context(.{});
		defer tc.deinit();

		tc.web.json(.{.type = "link"});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "title"});
		try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "text"});
	}

	{
		var tc = t.context(.{});
		defer tc.deinit();

		tc.web.json(.{.type = "long"});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "title"});
		try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "text"});
	}
}

test "posts.create: simple" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 3913});
	tc.web.json(.{.type = "simple", .text = "hello world!"});
	try handler(tc.env(), tc.web.req, tc.web.res);

	const body = (try tc.web.getJson()).object;
	const id = body.get("id").?.string;

	const row = tc.getDataRow("select * from posts where id = ?1", .{&(try uuid.parse(id))}).?;
	try t.expectEqual(3913, row.get(i64, "user_id").?);
	try t.expectString("simple", row.get([]u8, "type").?);
	try t.expectString("hello world!", row.get([]u8, "text").?);
	try t.expectEqual(null, row.get([]u8, "title"));
	try t.expectDelta(std.time.timestamp(), row.get(i64, "created").?, 2);
	try t.expectDelta(std.time.timestamp(), row.get(i64, "updated").?, 2);
}

test "posts.create: link" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 3914});
	tc.web.json(.{.type = "link", .title = "FFmpeg - The Ultimate Guide", .text = "img.ly/blog/ultimate-guide-to-ffmpeg/"});
	try handler(tc.env(), tc.web.req, tc.web.res);

	const body = (try tc.web.getJson()).object;
	const id = body.get("id").?.string;

	const row = tc.getDataRow("select * from posts where id = ?1", .{&(try uuid.parse(id))}).?;
	try t.expectEqual(3914, row.get(i64, "user_id").?);
	try t.expectString("link", row.get([]u8, "type").?);
	try t.expectString("https://img.ly/blog/ultimate-guide-to-ffmpeg/", row.get([]u8, "text").?);
	try t.expectString("FFmpeg - The Ultimate Guide", row.get([]u8, "title").?);
	try t.expectDelta(std.time.timestamp(), row.get(i64, "created").?, 2);
	try t.expectDelta(std.time.timestamp(), row.get(i64, "updated").?, 2);
}

test "posts.create: long" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 3914});
	tc.web.json(.{.type = "long", .title = "A Title", .text = "Some content\nOk"});
	try handler(tc.env(), tc.web.req, tc.web.res);

	const body = (try tc.web.getJson()).object;
	const id = body.get("id").?.string;

	const row = tc.getDataRow("select * from posts where id = ?1", .{&(try uuid.parse(id))}).?;
	try t.expectEqual(3914, row.get(i64, "user_id").?);
	try t.expectString("long", row.get([]u8, "type").?);
	try t.expectString("Some content\nOk", row.get([]u8, "text").?);
	try t.expectString("A Title", row.get([]u8, "title").?);
	try t.expectDelta(std.time.timestamp(), row.get(i64, "created").?, 2);
	try t.expectDelta(std.time.timestamp(), row.get(i64, "updated").?, 2);
}
