const std = @import("std");
const uuid = @import("uuid");
const httpz = @import("httpz");
const validate = @import("validate");
const raw_json = @import("raw_json");
const posts = @import("_posts.zig");

const web = posts.web;
const aolium = web.aolium;
const Allocator = std.mem.Allocator;

var show_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	show_validator = builder.object(&.{
		builder.field("username", builder.string(.{.required = true, .max = aolium.MAX_USERNAME_LEN, .trim = true})),
		builder.field("html", builder.boolean(.{.parse = true})),
		builder.field("comments", builder.boolean(.{.parse = true})),
	}, .{});
}

pub fn handler(env: *aolium.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateQuery(req, &[_][]const u8{"username", "html", "comments"}, show_validator, env);
	const post_id = try web.parseUUID("id", req.params.get("id").?, env);

	const app = env.app;
	const username = input.get([]u8, "username").?;
	const user = try app.getUserFromUsername(username) orelse {
		return web.notFound(res, "username doesn't exist");
	};

	const html = input.get(bool, "html") orelse false;
	const comments = input.get(bool, "comments") orelse false;
	const fetcher = PostFetcher.init(req.arena, env, post_id, user, html, comments);

	const cached_response = (try app.http_cache.fetch(*const PostFetcher, &fetcher.cache_key, getPost, &fetcher, .{.ttl = 300})) orelse {
		return web.notFound(res, "post not found");
	};
	defer cached_response.release();
	res.header("Cache-Control", "public,max-age=30");
	try cached_response.value.write(res);
}

const PostFetcher = struct {
	html: bool,
	comments: bool,
	post_id: [16]u8,
	env: *aolium.Env,
	user: aolium.User,
	cache_key: [17]u8,
	arena: std.mem.Allocator,

	fn init(arena: Allocator, env: *aolium.Env, post_id: [16]u8, user: aolium.User, html: bool, comments: bool) PostFetcher {
		// post_id + (html | comments)
		// 16      + 1
		var cache_key: [17]u8 = undefined;
		@memcpy(cache_key[0..16], &post_id);
		cache_key[16] = if (html) 1 else 0;
		cache_key[16] |= if (comments) 2 else 0;

		return .{
			.env = env,
			.user = user,
			.html = html,
			.arena = arena,
			.post_id = post_id,
			.comments = comments,
			.cache_key = cache_key,
		};
	}
};

fn getPost(fetcher: *const PostFetcher, _: []const u8) !?web.CachedResponse {
	const env = fetcher.env;
	const html = fetcher.html;
	const user = fetcher.user;
	const post_id = fetcher.post_id;

	const app = env.app;
	var sb = try app.buffers.acquireWithAllocator(fetcher.arena);
	defer app.buffers.release(sb);

	const prefix = "{\"post\":\n";
	try sb.write(prefix);
	var writer = sb.writer();

	{
		// this block exists so that conn is released ASAP

		const conn = app.getDataConn(user.shard_id);
		defer app.releaseDataConn(conn, user.shard_id);

		{
			const sql =
				\\ select type, title, text, tags, created, updated
				\\ from posts where id = ?1 and user_id = ?2
			;
			var row = conn.row(sql, .{&post_id, user.id}) catch |err| {
				return aolium.sqliteErr("posts.get", err, conn, env.logger);
			} orelse {
				return null;
			};
			defer row.deinit();

			const tpe = row.text(0);
			const text_value = posts.maybeRenderHTML(html, tpe, row, 2);
			defer text_value.deinit();

			var id_buf: [36]u8 = undefined;
			try std.json.stringify(.{
				.id = uuid.toString(&post_id, &id_buf),
				.type = tpe,
				.title = row.nullableText(1),
				.text = text_value.value(),
				.tags = raw_json.init(row.nullableText(3)),
				.created = row.int(4),
				.updated = row.int(5),
				.user_id = user.id,
			}, .{.emit_null_optional_fields = false}, writer);
		}

		if (fetcher.comments) {
			try sb.write(",\n\"comments\":[\n");

			{
				const sql =
					\\ select id, name, comment, created
					\\ from comments where post_id = ?1 and approved is not null
				;
				var rows = conn.rows(sql, .{&post_id}) catch |err| {
					return aolium.sqliteErr("posts.get.comments", err, conn, env.logger);
				};
				defer rows.deinit();

				var has_comments = false;
				while (rows.next()) |row| {
					var id_buf: [36]u8 = undefined;
					const id = uuid.toString(row.blob(0), &id_buf);
					try std.json.stringify(.{
						.id = id,
						.username = row.text(1),
						.comment = row.text(2),
						.created = row.int(3),
					}, .{.emit_null_optional_fields = false}, writer);

					try sb.write(",\n");
					has_comments = true;
				}

				if (rows.err) |err| {
					return aolium.sqliteErr("posts.get.comments.rows", err, conn, env.logger);
				}

				if (has_comments) {
					sb.truncate(2);
				}
			}

			try sb.write("\n]");
		}
	}

	try sb.writeByte('}');
	return .{
		.status = 200,
		.content_type = .JSON,
		.body = try sb.copy(app.http_cache.allocator),
	};
}

const t = aolium.testing;
test "posts.show: missing username" {
	var tc = t.context(.{});
	defer tc.deinit();
	try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
	try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "username"});
}

test "posts.show: invalid id" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 1});
	tc.web.param("id", "nope");
	tc.web.query("username", "unknown");
	try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
	try tc.expectInvalid(.{.code = validate.codes.TYPE_UUID, .field = "id"});
}

test "posts.show: unknown username" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.web.param("id", "bfddbd53-97ab-4531-9671-8bad4af425f4");
	tc.web.query("username", "unknown");
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);
	try tc.web.expectJson(.{.desc = "username doesn't exist", .code = 3});
}

test "posts.show: no posts" {
	var tc = t.context(.{});
	defer tc.deinit();

	_ = tc.insert.user(.{.username = "post_show_missing"});
	tc.web.param("id", "b646aead-8f41-4c96-bdee-bff025b0816c");
	tc.web.query("username", "post_show_missing");

	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);
}

test "posts.show: show" {
	var tc = t.context(.{});
	defer tc.deinit();

	const uid = tc.insert.user(.{.username = "index_post_show"});
	const p1 = tc.insert.post(.{.user_id = uid, .type = "simple", .text = "the spice must flow", .tags = &.	{"tag1", "tag2"}});
	const p2 = tc.insert.post(.{.user_id = uid, .type = "link", .title = "t2", .text = "https://www.aolium.dev"});
	const p3 = tc.insert.post(.{.user_id = uid, .type = "long", .title = "t1", .text = "### c1\n\nhi\n\n"});

	// test the cache too
	for (0..2) |_| {
		{
			tc.reset();
			tc.web.param("id", p1);
			tc.web.query("username", "index_post_show");

			try handler(tc.env(), tc.web.req, tc.web.res);
			try tc.web.expectJson(.{
				.post = .{
					.id = p1,
					.type = "simple",
					.text = "the spice must flow",
					.tags = .{"tag1", "tag2"},
				}
			});
		}

		{
			tc.reset();
			tc.web.param("id", p2);
			tc.web.query("username", "index_post_show");

			try handler(tc.env(), tc.web.req, tc.web.res);
			try tc.web.expectJson(.{
				.post = .{
					.id = p2,
					.type = "link",
					.title = "t2", .text = "https://www.aolium.dev",
					.tags = null
				}
			});
		}

		{
			tc.reset();
			tc.web.param("id", p3);
			tc.web.query("username", "index_post_show");

			try handler(tc.env(), tc.web.req, tc.web.res);
			try tc.web.expectJson(.{
				.post = .{
					.id = p3,
					.type = "long",
					.title = "t1",
					.tags = null,
					.text = "### c1\n\nhi\n\n"
				}
			});
		}

		// Now with html=true
		{
			tc.reset();
			tc.web.param("id", p1);
			tc.web.query("username", "index_post_show");
			tc.web.query("html", "true");

			try handler(tc.env(), tc.web.req, tc.web.res);
			try tc.web.expectJson(.{.post = .{.id = p1, .type = "simple", .text = "<p>the spice must flow</p>\n"}});
		}

		{
			tc.reset();
			tc.web.param("id", p2);
			tc.web.query("username", "index_post_show");
			tc.web.query("html", "true");

			try handler(tc.env(), tc.web.req, tc.web.res);
			try tc.web.expectJson(.{.post = .{.id = p2, .type = "link", .title = "t2", .text = "https://www.aolium.dev"}});
		}

		{
			tc.reset();
			tc.web.param("id", p3);
			tc.web.query("username", "index_post_show");
			tc.web.query("html", "true");

			try handler(tc.env(), tc.web.req, tc.web.res);
			try tc.web.expectJson(.{.post = .{.id = p3, .type = "long", .title = "t1", .text = "<h3>c1</h3>\n<p>hi</p>\n"}});
		}
	}
}
