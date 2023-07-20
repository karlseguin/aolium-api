const std = @import("std");
const uuid = @import("uuid");
const httpz = @import("httpz");
const validate = @import("validate");
const posts = @import("_posts.zig");

const web = posts.web;
const pondz = web.pondz;

var index_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	index_validator = builder.object(&.{
		builder.field("username", builder.string(.{.required = true, .max = pondz.MAX_USERNAME_LEN, .trim = true})),
	}, .{});
}

pub fn handler(env: *pondz.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateQuery(req, &[_][]const u8{"username"}, index_validator, env);

	const app = env.app;

	// returns an (optional) *cache.Entry which we must release to let the cache
	// know that we're done with it
	const user_entry = (try app.getUserFromUsername(input.get([]u8, "username").?)) orelse {
		env._validator.?.addInvalidField(.{
			.field = "username",
			.err = "does not exist",
			.code = pondz.val.UNKNOWN_USERNAME,
		});
		return error.Validation;
	};
	defer user_entry.release();

	const user = user_entry.value;

	const sql =
		\\ select id, title, link, text, created, updated
		\\ from posts
		\\ where user_id = ?1
		\\ order by created desc
		\\ limit 20
	;
	const args = .{user.id};

	const conn = app.getDataConn(user.shard_id);
	defer app.releaseDataConn(conn, user.shard_id);

	var rows = conn.rows(sql, args) catch |err| {
		return pondz.sqliteErr("posts.select", err, conn, env.logger);
	};
	defer rows.deinit();

	// It would be simpler to loop through rows, collecting "Posts" into an arraylist
	// and then using json.stringify(.{.posts = posts}). But if we did that, we'd
	// need to dupe the text values so that they outlive a single iteration of the
	// loop. Instead, we serialize each post immediately and glue everything together.
	var sb = try app.buffers.acquireWithAllocator(res.arena);
	defer app.buffers.release(sb);
	const prefix = "{\"posts\":[\n";
	try sb.write(prefix);
	var writer = sb.writer();


	// TODO: can/should heavily optimzie this, namely by storing pre-generated
	// json and html blobs that we just glue together.
	while (rows.next()) |row| {
		var id_buf: [36]u8 = undefined;
		try std.json.stringify(.{
			.id = uuid.toString(row.blob(0), &id_buf),
			.title = row.nullableText(1),
			.link = row.nullableText(2),
			.text = row.nullableText(3),
			.created = row.int(4),
			.updated = row.int(5),
		}, .{}, writer);

		try sb.write(",\n");
	}

	if (rows.err) |err| {
		return pondz.sqliteErr("posts.select.rows", err, conn, env.logger);
	}

	// strip out the last comma and newline, if we wrote anything
	if (sb.len() > prefix.len) {
		sb.truncate(2);
	}
	try sb.write("\n]}");

	res.content_type = .JSON;
	res.body = sb.string();
	// Force the write now, since sb won't be valid after we return.
	try res.write();
}

const t = pondz.testing;
test "posts.index: missing username" {
	var tc = t.context(.{});
	defer tc.deinit();
	try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
	try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "username"});
}

test "posts.index: unknown username" {
	var tc = t.context(.{});
	defer tc.deinit();
	tc.web.query("username", "unknown");
	try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
	try tc.expectInvalid(.{.code = pondz.val.UNKNOWN_USERNAME, .field = "username"});
}

test "posts.index: no posts" {
	var tc = t.context(.{});
	defer tc.deinit();

	_ = tc.insert.user(.{.username = "index_no_post"});
	tc.web.query("username", "index_no_post");

	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectJson(.{.posts = .{}});
}

test "posts.index: json posts" {
	var tc = t.context(.{});
	defer tc.deinit();

	const uid = tc.insert.user(.{.username = "index_post_list"});
	const p1 = tc.insert.post(.{.user_id = uid, .created = 10});
	const p2 = tc.insert.post(.{.user_id = uid, .created = 12, .title = "t1", .link = "l1", .text = "c1"});
	_ = tc.insert.post(.{.created = 10});

	tc.web.query("username", "index_post_list");

	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectJson(.{.posts = .{
		.{
			.id = p2,
			.title = "t1",
			.link = "l1",
			.text = "c1",
		},
		.{
			.id = p1,
			.title = null,
			.link = null,
			.text = null,
		}
	}});
}
