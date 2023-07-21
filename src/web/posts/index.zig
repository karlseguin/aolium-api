const std = @import("std");
const uuid = @import("uuid");
const httpz = @import("httpz");
const zqlite = @import("zqlite");
const markdown = @import("markdown");
const validate = @import("validate");
const posts = @import("_posts.zig");

const web = posts.web;
const pondz = web.pondz;

var index_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	index_validator = builder.object(&.{
		builder.field("username", builder.string(.{.required = true, .max = pondz.MAX_USERNAME_LEN, .trim = true})),
		builder.field("html", builder.boolean(.{.parse = true})),
	}, .{});
}

pub fn handler(env: *pondz.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateQuery(req, &[_][]const u8{"username", "html"}, index_validator, env);

	const app = env.app;
	const username = input.get([]u8, "username").?;
	const user = try getUser(app, username) orelse {
		return web.notFound(res, "username doesn't exist");
	};

	const html = input.get(bool, "html") orelse false;

	var fetcher = PostFetcher{
		.env = env,
		.user = user,
		.arena = res.arena,
		.html = input.get(bool, "html") orelse false,
	};

	// 8 byte id + html bool
	var cache_key_buf: [9]u8 = undefined;
	@memcpy(cache_key_buf[0..8], std.mem.asBytes(&user.id));
	cache_key_buf[8] = if (html) 1 else 0;
	const cache_key = cache_key_buf[0..];

	const cached_response = (try app.http_cache.fetch(*PostFetcher, cache_key, getPosts, &fetcher, .{.ttl = 300})).?;
	defer cached_response.release();
	res.header("Cache-Control", "private,max-age=30");
	try cached_response.value.write(res);
}

fn getUser(app: *pondz.App, username: []const u8) !?pondz.User {
	const user_entry = (try app.getUserFromUsername(username)) orelse return null;
	const user = user_entry.value;
	user_entry.release();
	return user;
}

const PostFetcher = struct {
	html: bool,
	env: *pondz.Env,
	user: pondz.User,
	arena: std.mem.Allocator,
};

fn getPosts(fetcher: *const PostFetcher, _: []const u8) !?web.CachedResponse {
	const env = fetcher.env;
	const html = fetcher.html;
	const user = fetcher.user;

	const sql =
		\\ select id, type, title, text, created, updated
		\\ from posts
		\\ where user_id = ?1
		\\ order by created desc
		\\ limit 20
	;
	const args = .{user.id};

	const app = env.app;
	var sb = try app.buffers.acquireWithAllocator(fetcher.arena);
	defer app.buffers.release(sb);

	const prefix = "{\"posts\":[\n";
	try sb.write(prefix);
	var writer = sb.writer();

	{
		// this block exists so that conn is released ASAP, specifically avoiding
		// the sb.copy

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


		// TODO: can/should heavily optimzie this, namely by storing pre-generated
		// json and html blobs that we just glue together.
		while (rows.next()) |row| {
			const text_value = maybeRender(html, row, 3);
			defer text_value.deinit();

			var id_buf: [36]u8 = undefined;
			try std.json.stringify(.{
				.id = uuid.toString(row.blob(0), &id_buf),
				.type = row.nullableText(1),
				.title = row.nullableText(2),
				.text = text_value.value(),
				.created = row.int(4),
				.updated = row.int(5),
			}, .{.emit_null_optional_fields = false}, writer);

			try sb.write(",\n");
		}

		if (rows.err) |err| {
			return pondz.sqliteErr("posts.select.rows", err, conn, env.logger);
		}
	}

	// strip out the last comma and newline, if we wrote anything
	if (sb.len() > prefix.len) {
		sb.truncate(2);
	}
	try sb.write("\n]}");

	return .{
		.status = 200,
		.content_type = .JSON,
		.body = try sb.copy(app.http_cache.allocator),
	};
}

// We optionally render markdown to HTML. If we _don't_, then things are
// straightforward and we return the text column from sqlite as-is.
// However, if we _are_ rendering, we (a) need a null-terminated string
// from sqlite (because that's what cmark wants) and we need to free the
// result.
fn maybeRender(html: bool, row: zqlite.Row, index: usize) RenderResult {
	if (!html) {
		return .{.raw = row.nullableText(index)};
	}

	const value = row.nullableTextZ(index) orelse {
		return .{.raw = null};
	};

	// we're here because we've been asked to render the value to HTML and
	// we actually have a value
	return .{.html = markdown.toHTML(value, row.textLen(index))};
}

// Wraps a nullable text column which may be raw or may be rendered html from
// markdown. This wrapper allows our caller to call .value() and .deinit()
// without having to know anything.
const RenderResult = union(enum) {
	raw: ?[]const u8,
	html: markdown.Result,

	fn value(self: RenderResult) ?[]const u8 {
		return switch (self) {
			.raw => |v| v,
			.html => |html| std.mem.span(html.value),
		};
	}

	fn deinit(self: RenderResult) void {
		switch (self) {
			.raw => {},
			.html => |html| html.deinit(),
		}
	}
};

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
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);
	try tc.web.expectJson(.{.desc = "username doesn't exist", .code = 3});
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
	const p1 = tc.insert.post(.{.user_id = uid, .created = 10, .type = "simple", .text = "the spice must flow"});
	const p2 = tc.insert.post(.{.user_id = uid, .created = 12, .type = "long", .title = "t1",  .text = "### c1\n\nhi\n\n"});
	_ = tc.insert.post(.{.created = 10});

	// test the cache too
	for (0..2) |_| {
		{
			// raw output
			tc.reset();
			tc.web.query("username", "index_post_list");

			try handler(tc.env(), tc.web.req, tc.web.res);
			try tc.web.expectJson(.{.posts = .{
				.{
					.id = p2,
					.type = "long",
					.title = "t1",
					.text = "### c1\n\nhi\n\n",
				},
				.{
					.id = p1,
					.type = "simple",
					.text = "the spice must flow",
				}
			}});
		}

		{
			// html output
			tc.reset();
			tc.web.query("html", "true");
			tc.web.query("username", "index_post_list");

			try handler(tc.env(), tc.web.req, tc.web.res);
			try tc.web.expectJson(.{.posts = .{
				.{
					.id = p2,
					.type = "long",
					.title = "t1",
					.text = "<h3>c1</h3>\n<p>hi</p>\n",
				},
				.{
					.id = p1,
					.type = "simple",
					.text = "<p>the spice must flow</p>\n",
				}
			}});
		}
	}
}
