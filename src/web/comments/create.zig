const std = @import("std");
const zul = @import("zul");
const httpz = @import("httpz");
const validate = @import("validate");
const comments = @import("_comments.zig");

const web = comments.web;
const aolium = web.aolium;

var create_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	create_validator = builder.object(&.{
		builder.field("name", builder.string(.{.trim = true, .max = 100})),
		builder.field("comment", builder.string(.{.required = true, .trim = true, .max = 2000, .function = validateComment})),
		builder.field("username", builder.string(.{.required = true, .max = aolium.MAX_USERNAME_LEN, .trim = true})),
	}, .{});
}

pub fn handler(env: *aolium.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateJson(req, create_validator, env);
	const post_id = try web.parseUUID("id", req.params.get("id").?, env);

	const app = env.app;
	const post_author = try app.getUserFromUsername(input.get("username").?.string) orelse {
		return web.notFound(res, "username doesn't exist");
	};
	const post_author_id = post_author.id;

	const comment = input.get("comment").?.string;

	var approved: ?i64 = null;
	var commentor_id: ?i64 = null;
	var name: ?[]const u8 = null;

	if (env.user) |u| {
		name = u.username;
		commentor_id = u.id;
		if (u.id == post_author_id) {
			approved = std.time.timestamp();
		}
	} else if (input.get("name")) |n| {
		name = n.string;
	}

	const comment_id = zul.UUID.v4();

	{
		const conn = app.getDataConn(post_author.shard_id);
		defer app.releaseDataConn(conn, post_author.shard_id);

		const get_post_sql = "select 1 from posts where id = ?1 and user_id = ?2";
		const row = conn.row(get_post_sql, .{&post_id.bin, post_author_id}) catch |err| {
			return aolium.sqliteErr("comments.select", err, conn, env.logger);
		} orelse {
			return web.notFound(res, "post doesn't exist");
		};
		row.deinit();

		const insert_comment_sql = "insert into comments (id, post_id, user_id, name, comment, approved) values (?1, ?2, ?3, ?4, ?5, ?6)";
		conn.exec(insert_comment_sql, .{&comment_id.bin, &post_id.bin, commentor_id, name, comment, approved}) catch |err| {
			return aolium.sqliteErr("comments.insert", err, conn, env.logger);
		};

		if (approved != null) {
			const update_post_sql = "update posts set comments = comments + 1 where id = ?1";
			conn.exec(update_post_sql, .{&post_id.bin}) catch |err| {
				return aolium.sqliteErr("comments.post_update", err, conn, env.logger);
			};
			app.clearPostCache(post_id);
		}
	}

	return res.json(.{.id = comment_id}, .{});
}

fn validateComment(value: ?[]const u8, context: *validate.Context(void)) !?[]const u8 {
	const comment = value.?;
	const pos = std.ascii.indexOfIgnoreCase(comment, "http") orelse return comment;
	if (pos + 10 > comment.len) {
		return comment;
	}

	var next = pos + 4;
	if (comment[next] == 's') {
			next += 1;
	}

	if (std.mem.eql(u8, comment[next..next+3], "://") == false) {
		return comment;
	}

	try context.add(.{
		.code = aolium.val.LINK_IN_COMMENT,
		.err = "links are not allowed in comments",
	});

	return comment;
}

const t = aolium.testing;
test "comments.create: empty body" {
	var tc = t.context(.{});
	defer tc.deinit();
	try t.expectError(error.InvalidJson, handler(tc.env(), tc.web.req, tc.web.res));
}

test "comments.create: invalid json body" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.body("{hi");
	try t.expectError(error.InvalidJson, handler(tc.env(), tc.web.req, tc.web.res));
}

test "comments.create: invalid input" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.json(.{.x = 1, .name = 32});
	try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
	try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "comment"});
	try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "username"});
	try tc.expectInvalid(.{.code = validate.codes.TYPE_STRING, .field = "name"});
}

test "comments.create: unknown user" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.param("id", try zul.UUID.v4().toHexAlloc(tc.arena, .lower));
	tc.web.json(.{.comment = "It", .username = "unknown-user"});
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);
}

test "comments.create: unknown post" {
	var tc = t.context(.{});
	defer tc.deinit();

	_ = tc.insert.user(.{.username = "common-unknown-post"});
	const post_id = tc.insert.post(.{.user_id = 0, });

	tc.web.param("id", post_id);
	tc.web.json(.{.comment = "It", .username = "common-unknown-post"});
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);
}

test "comments.create: link in comment" {
	var tc = t.context(.{});
	defer tc.deinit();

	const uid1 = tc.insert.user(.{.username = "anon-comment-1"});
	const post_id = tc.insert.post(.{.user_id = uid1, });

	{
		tc.web.param("id", post_id);
		tc.web.json(.{.comment = "my spam http://www.example.com", .username = "anon-comment-1"});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = aolium.val.LINK_IN_COMMENT, .field = "comment"});
	}

	{
		// https
		tc.reset();
		tc.web.param("id", post_id);
		tc.web.json(.{.comment = "my spam https://www.example.com", .username = "anon-comment-1"});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = aolium.val.LINK_IN_COMMENT, .field = "comment"});
	}
}

test "comments.create: anonymous" {
	var tc = t.context(.{});
	defer tc.deinit();

	const uid1 = tc.insert.user(.{.username = "anon-comment-1"});
	const post_id = tc.insert.post(.{.user_id = uid1, });

	tc.web.param("id", post_id);
	tc.web.json(.{.comment = "I think you are wrong and stupid!", .username = "anon-comment-1"});
	try handler(tc.env(), tc.web.req, tc.web.res);

	const body = (try tc.web.getJson()).object;
	const id = try zul.UUID.parse(body.get("id").?.string);

	const row = tc.getDataRow("select * from comments where id = ?1", .{&id.bin}).?;
	try t.expectEqual(true, row.get("user_id").?.isNull());
	try t.expectEqual(true, row.get("name").?.isNull());
	try t.expectEqual(true, row.get("approved").?.isNull());
	try t.expectSlice(u8, &(try zul.UUID.parse(post_id)).bin, row.get("post_id").?.string);
	try t.expectString("I think you are wrong and stupid!", row.get("comment").?.string);
	try t.expectDelta(std.time.timestamp(), row.get("created").?.i64, 2);
}

test "comments.create: from non-author user" {
	var tc = t.context(.{});
	defer tc.deinit();

	const uid1 = tc.insert.user(.{.username = "user-comment-2a"});
	const uid2 = tc.insert.user(.{.username = "user-comment-2b"});
	const post_id = tc.insert.post(.{.user_id = uid2});

	tc.user(.{.id = uid1, .username = "user-comment-2a"});
	tc.web.param("id", post_id);
	tc.web.json(.{.comment = "no you are", .username = "user-comment-2b"});
	try handler(tc.env(), tc.web.req, tc.web.res);

	const body = (try tc.web.getJson()).object;
	const id = try zul.UUID.parse(body.get("id").?.string);

	const row = tc.getDataRow("select * from comments where id = ?1", .{&id.bin}).?;
	try t.expectEqual(uid1, row.get("user_id").?.i64);
	try t.expectString("user-comment-2a", row.get("name").?.string);
	try t.expectString("no you are", row.get("comment").?.string);
	try t.expectDelta(std.time.timestamp(), row.get("created").?.i64, 2);
	try t.expectSlice(u8, &(try zul.UUID.parse(post_id)).bin, row.get("post_id").?.string);
	try t.expectEqual(true, row.get("approved").?.isNull());
}

test "comments.create: from author" {
	var tc = t.context(.{});
	defer tc.deinit();


	const uid1 = tc.insert.user(.{.username = "author-comment-1"});
	const post_id = tc.insert.post(.{.user_id = uid1, });

	tc.user(.{.id = uid1, .username = "author-comment-1"});
	tc.web.param("id", post_id);
	tc.web.json(.{.comment = "no you are", .username = "author-comment-1"});
	try handler(tc.env(), tc.web.req, tc.web.res);

	const body = (try tc.web.getJson()).object;
	const id = try zul.UUID.parse(body.get("id").?.string);

	const row = tc.getDataRow("select * from comments where id = ?1", .{&id.bin}).?;
	try t.expectEqual(uid1, row.get("user_id").?.i64);
	try t.expectString("author-comment-1", row.get("name").?.string);
	try t.expectString("no you are", row.get("comment").?.string);
	try t.expectDelta(std.time.timestamp(), row.get("created").?.i64, 2);
	try t.expectSlice(u8, &(try zul.UUID.parse(post_id)).bin, row.get("post_id").?.string);
	try t.expectDelta(std.time.timestamp(), row.get("approved").?.i64, 2);
}
