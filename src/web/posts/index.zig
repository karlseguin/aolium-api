const std = @import("std");
const uuid = @import("uuid");
const httpz = @import("httpz");
const validate = @import("validate");
const posts = @import("_posts.zig");

const web = posts.web;
const aolium = web.aolium;
const Allocator = std.mem.Allocator;

var index_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	index_validator = builder.object(&.{
		builder.field("username", builder.string(.{.required = true, .max = aolium.MAX_USERNAME_LEN, .trim = true})),
		builder.field("html", builder.boolean(.{.parse = true})),
		builder.field("page", builder.int(u16, .{.parse = true, .min = 1})),
	}, .{});
}

pub fn handler(env: *aolium.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateQuery(req, &[_][]const u8{"username", "html"}, index_validator, env);

	const app = env.app;
	const username = input.get([]u8, "username").?;
	const user = try app.getUserFromUsername(username) orelse {
		return web.notFound(res, "username doesn't exist");
	};

	const page = input.get(u16, "page") orelse 1;
	const html = input.get(bool, "html") orelse false;
	const fetcher = PostsFetcher.init(req.arena, env, user, page, html);

	const cached_response = (try app.http_cache.fetch(*const PostsFetcher, &fetcher.cache_key, getPosts, &fetcher, .{.ttl = 300})).?;
	defer cached_response.release();
	res.header("Cache-Control", "public,max-age=30");
	try cached_response.value.write(res);
}

const PostsFetcher = struct {
	html: bool,
	page: u16,
	env: *aolium.Env,
	user: aolium.User,
	cache_key: [11]u8,
	arena: std.mem.Allocator,

	fn init(arena: Allocator, env: *aolium.Env, user: aolium.User, page: u16, html: bool) PostsFetcher {
		// user_id + page + html
		// 8       + 2    + 1
		var cache_key: [11]u8 = undefined;
		@memcpy(cache_key[0..8], std.mem.asBytes(&user.id));
		@memcpy(cache_key[8..10], std.mem.asBytes(&page));
		cache_key[10] = if (html) 1 else 0;

		return .{
			.env = env,
			.user = user,
			.page = page,
			.html = html,
			.arena = arena,
			.cache_key = cache_key,
		};
	}
};

fn getPosts(fetcher: *const PostsFetcher, _: []const u8) !?web.CachedResponse {
	const env = fetcher.env;
	const html = fetcher.html;
	const user = fetcher.user;

	const offset = (fetcher.page - 1) * 20;

	const sql =
		\\ select id, type, title,
		\\   case type
		\\     when 'long' then null
		\\     else text
		\\   end as text,
		\\   created, updated
		\\ from posts
		\\ where user_id = ?1
		\\ order by created desc
		\\ limit 20 offset ?2
	;
	const args = .{user.id, offset};

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
			return aolium.sqliteErr("posts.select", err, conn, env.logger);
		};
		defer rows.deinit();

		// It would be simpler to loop through rows, collecting "Posts" into an arraylist
		// and then using json.stringify(.{.posts = posts}). But if we did that, we'd
		// need to dupe the text values so that they outlive a single iteration of the
		// loop. Instead, we serialize each post immediately and glue everything together.

		// TODO: can/should heavily optimzie this, namely by storing pre-generated
		// json and html blobs that we just glue together.
		while (rows.next()) |row| {
			const tpe = row.text(1);

			const text_value = posts.maybeRenderHTML(html, tpe, row, 3);
			defer text_value.deinit();

			var id_buf: [36]u8 = undefined;
			try std.json.stringify(.{
				.id = uuid.toString(row.blob(0), &id_buf),
				.type = tpe,
				.title = row.nullableText(2),
				.text = text_value.value(),
				.created = row.int(4),
				.updated = row.int(5),
			}, .{.emit_null_optional_fields = false}, writer);

			try sb.write(",\n");
		}

		if (rows.err) |err| {
			return aolium.sqliteErr("posts.select.rows", err, conn, env.logger);
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

const t = aolium.testing;
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

test "posts.index: list" {
	var tc = t.context(.{});
	defer tc.deinit();

	const uid = tc.insert.user(.{.username = "index_post_list"});
	const p1 = tc.insert.post(.{.user_id = uid, .created = 10, .type = "simple", .text = "the spice must flow"});
	const p2 = tc.insert.post(.{.user_id = uid, .created = 15, .type = "link", .title = "t2", .text = "https://www.aolium.dev"});
	const p3 = tc.insert.post(.{.user_id = uid, .created = 12, .type = "long", .title = "t1", .text = "### c1\n\nhi\n\n"});
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
					.type = "link",
					.title = "t2",
					.text = "https://www.aolium.dev",
				},
				.{
					.id = p3,
					.type = "long",
					.title = "t1",
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
					.type = "link",
					.title = "t2",
					.text = "https://www.aolium.dev",
				},
				.{
					.id = p3,
					.type = "long",
					.title = "t1",
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
