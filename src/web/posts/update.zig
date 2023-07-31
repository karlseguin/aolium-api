const std = @import("std");
const uuid = @import("uuid");
const httpz = @import("httpz");
const validate = @import("validate");
const posts = @import("_posts.zig");

const web = posts.web;
const aolium = web.aolium;

pub fn handler(env: *aolium.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateJson(req, posts.create_validator, env);
	const post_id = try web.parseUUID("id", req.params.get("id").?, env);

	const user = env.user.?;
	const post = try posts.Post.create(req.arena, input);

	const sql =
		\\ update posts
		\\ set title = ?3, text = ?4, type = ?5, tags = ?6, updated = unixepoch()
		\\ where id = ?1 and user_id = ?2
	;

	const args = .{&post_id, user.id, post.title, post.text, post.type, post.tags};

	const app = env.app;

	{
		// we want conn released ASAP
		const conn = app.getDataConn(user.shard_id);
		defer app.releaseDataConn(conn, user.shard_id);

		conn.exec(sql, args) catch |err| {
			return aolium.sqliteErr("posts.update", err, conn, env.logger);
		};

		if (conn.changes() == 0) {
			return web.notFound(res, "the post could not be found");
		}
	}

	app.clearUserCache(user.id);
	app.clearPostCache(&post_id);
	res.status = 204;
}

const t = aolium.testing;
test "posts.update: empty body" {
	var tc = t.context(.{});
	defer tc.deinit();
	try t.expectError(error.InvalidJson, handler(tc.env(), tc.web.req, tc.web.res));
}

test "posts.update: invalid json body" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.body("{hi");
	try t.expectError(error.InvalidJson, handler(tc.env(), tc.web.req, tc.web.res));
}

test "posts.update: invalid input" {
	{
		var tc = t.context(.{});
		defer tc.deinit();

		tc.web.json(.{.x = 1, .tags = 32});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "type"});
		try tc.expectInvalid(.{.code = validate.codes.TYPE_ARRAY, .field = "tags"});
	}

	{
		var tc = t.context(.{});
		defer tc.deinit();

		tc.web.json(.{.type = "melange", .tags = .{"hi", 3}});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.STRING_CHOICE, .field = "type"});
		try tc.expectInvalid(.{.code = validate.codes.TYPE_STRING, .field = "tags.1"});
	}

	{
		var tc = t.context(.{});
		defer tc.deinit();

		tc.web.json(.{.type = "simple", .tags = .{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a"}});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "text"});
		try tc.expectInvalid(.{.code = validate.codes.ARRAY_LEN_MAX, .field = "tags", .data = .{.max = 10}});
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
test "posts.update: invalid id" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 1});
	tc.web.param("id", "nope");
	tc.web.json(.{.type = "simple", .text = "a"});
	try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
	try tc.expectInvalid(.{.code = validate.codes.TYPE_UUID, .field = "id"});
}

test "posts.update: unknown id" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 1});
	tc.web.param("id", "4b0548fc-7127-438d-a87e-bc283f2d5981");
	tc.web.json(.{.type = "simple", .text = "hello world!!"});
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);
}

test "posts.update: post belongs to a different user" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 1});
	const id = tc.insert.post(.{.user_id = 4, .text = "hack-proof", .updated = 52, .created = 50});

	tc.web.param("id", id);
	tc.web.json(.{.type = "simple", .text = "hello world!!"});
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);

	const row = tc.getDataRow("select * from posts where id = ?1", .{&(try uuid.parse(id))}).?;
	try t.expectEqual(4, row.get(i64, "user_id").?);
	try t.expectString("simple", row.get([]u8, "type").?);
	try t.expectString("hack-proof", row.get([]u8, "text").?);
	try t.expectEqual(null, row.get([]u8, "title"));
	try t.expectEqual(50, row.get(i64, "created").?);
	try t.expectEqual(52, row.get(i64, "updated").?);
}

test "posts.update: simple" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 3913});
	const id = tc.insert.post(.{.user_id = 3913, .updated = 1000, .created = 33});

	tc.web.param("id", id);
	tc.web.json(.{.type = "simple", .text = "hello world!!"});
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(204);

	const row = tc.getDataRow("select * from posts where id = ?1", .{&(try uuid.parse(id))}).?;
	try t.expectEqual(3913, row.get(i64, "user_id").?);
	try t.expectString("simple", row.get([]u8, "type").?);
	try t.expectString("hello world!!", row.get([]u8, "text").?);
	try t.expectEqual(null, row.get([]u8, "title"));
	try t.expectEqual(33, row.get(i64, "created").?);
	try t.expectDelta(std.time.timestamp(), row.get(i64, "updated").?, 2);
}

test "posts.update: link" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 3914});
	const id = tc.insert.post(.{.user_id = 3914, .updated = 1500, .created = 222});

	tc.web.param("id", id);
	tc.web.json(.{.type = "link", .title = "FFmpeg - The Ultimate Guide", .text = "img.ly/blog/ultimate-guide-to-ffmpeg/"});
	try handler(tc.env(), tc.web.req, tc.web.res);

	const row = tc.getDataRow("select * from posts where id = ?1", .{&(try uuid.parse(id))}).?;
	try t.expectEqual(3914, row.get(i64, "user_id").?);
	try t.expectString("link", row.get([]u8, "type").?);
	try t.expectString("https://img.ly/blog/ultimate-guide-to-ffmpeg/", row.get([]u8, "text").?);
	try t.expectString("FFmpeg - The Ultimate Guide", row.get([]u8, "title").?);
	try t.expectEqual(222, row.get(i64, "created").?);
	try t.expectDelta(std.time.timestamp(), row.get(i64, "updated").?, 2);
}

test "posts.update: long" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 441});
	const id = tc.insert.post(.{.user_id = 441, .updated = -500, .created = 503});

	tc.web.param("id", id);
	tc.web.json(.{.type = "long", .title = "A Title!", .text = "Some !content\nOk", .tags = .{"t1", "soup"}});
	try handler(tc.env(), tc.web.req, tc.web.res);

	const row = tc.getDataRow("select * from posts where id = ?1", .{&(try uuid.parse(id))}).?;
	try t.expectEqual(441, row.get(i64, "user_id").?);
	try t.expectString("long", row.get([]u8, "type").?);
	try t.expectString("Some !content\nOk", row.get([]u8, "text").?);
	try t.expectString("A Title!", row.get([]u8, "title").?);
	try t.expectString("[\"t1\",\"soup\"]", row.get([]u8, "tags").?);
	try t.expectEqual(503, row.get(i64, "created").?);
	try t.expectDelta(std.time.timestamp(), row.get(i64, "updated").?, 2);
}
