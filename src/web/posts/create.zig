const std = @import("std");
const uuid = @import("uuid");
const httpz = @import("httpz");
const validate = @import("validate");
const posts = @import("_posts.zig");

const web = posts.web;
const pondz = web.pondz;

var create_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	create_validator = builder.object(&.{
		builder.field("title", builder.string(.{.max = 150, .trim = true})),
		builder.field("link", builder.string(.{.max = 200, .trim = true})),
		builder.field("text", builder.string(.{.max = 20_000, .trim = true})),
	}, .{});
}

pub fn handler(env: *pondz.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateJson(req, create_validator, env);

	const title = normalize(input.get([]u8, "title"));
	const text = normalize(input.get([]u8, "text"));
	const link = try normalizeLink(req.arena, input.get([]u8, "link"));

	if (text == null and link == null) {
		env._validator.?.addInvalidField(.{
			.field = "text",
			.err = "must provide either a link or text (or both)",
			.code = pondz.val.EMPTY_POST,
		});
		return error.Validation;
	}

	// dispatcher will make sure this is non-null
	const user = env.user.?;

	const post_id = uuid.bin();
	const sql = "insert into posts (id, user_id, title, link, text) values (?1, ?2, ?3, ?4, ?5)";
	const args = .{&post_id, user.id, title, link, text};

	const app = env.app;
	const conn = app.getDataConn(user.shard_id);
	defer app.releaseDataConn(conn, user.shard_id);

	conn.exec(sql, args) catch |err| {
		return pondz.sqliteErr("posts.insert", err, conn, env.logger);
	};

	var hex_uuid: [36]u8 = undefined;
	return res.json(.{
		.id = uuid.toString(post_id, &hex_uuid),
	}, .{});
}

fn normalize(optional: ?[]const u8) ?[]const u8 {
	const value = optional orelse return null;
	return if (value.len == 0) null else value;
}

// we know allocator is an arena
fn normalizeLink(allocator: std.mem.Allocator, optional_link: ?[]const u8) !?[]const u8 {
	const link = optional_link orelse return null;
	if (link.len == 0) {
		return null;
	}

	const has_http_prefix = blk: {
		if (link.len < 8) {
			break :blk false;
		}
		if (std.ascii.startsWithIgnoreCase(link, "http") == false) {
			break :blk false;
		}
		if (link[4] == ':' and link[5] == '/' and link[6] == '/') {
			break :blk true;
		}

		break :blk (link[4] == 's' or link[4] == 'S') and link[5] == ':' and link[6] == '/' and link[7] == '/';
	};

	if (has_http_prefix) {
		return link;
	}

	var prefixed = try allocator.alloc(u8, link.len + 8);
	@memcpy(prefixed[0..8], "https://");
	@memcpy(prefixed[8..], link);
	return prefixed;
}

const t = pondz.testing;
test "posts normalizeLink" {
	try t.expectEqual(null, normalizeLink(undefined, null));
	try t.expectEqual(null, normalizeLink(undefined, ""));
	try t.expectString("http://pondz.dev", (try normalizeLink(undefined, "http://pondz.dev")).?);
	try t.expectString("HTTP://pondz.dev", (try normalizeLink(undefined, "HTTP://pondz.dev")).?);
	try t.expectString("https://www.openmymind.net", (try normalizeLink(undefined, "https://www.openmymind.net")).?);
	try t.expectString("HTTPS://www.openmymind.net", (try normalizeLink(undefined, "HTTPS://www.openmymind.net")).?);

	{
		const link = (try normalizeLink(t.allocator, "pondz.dev")).?;
		defer t.allocator.free(link);
		try t.expectString("https://pondz.dev", link);
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

		tc.web.json(.{.title = 32, .link = true, .text = .{.a = true}});
		try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
		try tc.expectInvalid(.{.code = validate.codes.TYPE_STRING, .field = "title"});
		try tc.expectInvalid(.{.code = validate.codes.TYPE_STRING, .field = "link"});
		try tc.expectInvalid(.{.code = validate.codes.TYPE_STRING, .field = "text"});
	}
}

test "posts.create" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 3913});
	tc.web.json(.{.title = "a title", .link = "pondz.dev", .text = "the text"});
	try handler(tc.env(), tc.web.req, tc.web.res);

	const body = (try tc.web.getJson()).object;
	const id = body.get("id").?.string;

	const row = tc.getDataRow("select * from posts where id = ?1", .{&(try uuid.parse(id))}).?;
	try t.expectEqual(3913, row.get(i64, "user_id").?);
	try t.expectString("a title", row.get([]u8, "title").?);
	try t.expectString("https://pondz.dev", row.get([]u8, "link").?);
	try t.expectString("the text", row.get([]u8, "text").?);
	try t.expectDelta(std.time.timestamp(), row.get(i64, "created").?, 2);
	try t.expectDelta(std.time.timestamp(), row.get(i64, "updated").?, 2);
}
