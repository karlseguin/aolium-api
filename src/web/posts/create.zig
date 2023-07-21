const std = @import("std");
const uuid = @import("uuid");
const httpz = @import("httpz");
const typed = @import("typed");
const validate = @import("validate");
const posts = @import("_posts.zig");

const web = posts.web;
const pondz = web.pondz;

var create_validator: *validate.Object(void) = undefined;
var simple_validator: *validate.Object(void) = undefined;
var link_validator: *validate.Object(void) = undefined;
var long_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	create_validator = builder.object(&.{
		builder.field("type", builder.string(.{.required = true, .choices = &.{"simple", "link", "long"}})),
	}, .{.function = validatePost});

	simple_validator = builder.object(&.{
		builder.field("text", builder.string(.{.required = true, .max = 500})),
	}, .{});

	link_validator = builder.object(&.{
		builder.field("title", builder.string(.{.required = true, .max = 200})),
		builder.field("text", builder.string(.{.required = true, .max = 200})),
	}, .{});

	long_validator = builder.object(&.{
		builder.field("title", builder.string(.{.required = true, .max = 200})),
		builder.field("text", builder.string(.{.required = true, .max = 5000})),
	}, .{});
}

pub fn handler(env: *pondz.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateJson(req, create_validator, env);

	// type and text are always required
	const tpe = input.get([]u8, "type").?;
	const raw_text = normalize(input.get([]u8, "text")).?;
	const text = if (std.mem.eql(u8, tpe, "link")) try normalizeLink(req.arena, raw_text) else normalize(raw_text);

	// title isn't required for "simple"
	const title = normalize(input.get([]u8, "title"));

	// dispatcher will make sure this is non-null
	const user = env.user.?;

	const post_id = uuid.bin();
	const sql = "insert into posts (id, user_id, title, text, type) values (?1, ?2, ?3, ?4, ?5)";
	const args = .{&post_id, user.id, title, text, tpe};

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

// How the object is validated depends on the `type`
fn validatePost(optional: ?typed.Map, ctx: *validate.Context(void)) !?typed.Map {
	// validator won't come this far if the root isn't an object
	const input = optional.?;

	const PostType = enum {
		simple, link, long
	};

	const string_type = input.get([]u8, "type") orelse return null;

	// if type isn't valid, this will fail anyways, so return early
	const post_type = std.meta.stringToEnum(PostType, string_type) orelse return null;

	switch (post_type) {
		.simple => _ = return simple_validator.validate(input, ctx),
		.link => _ = return link_validator.validate(input, ctx),
		.long => _ = return long_validator.validate(input, ctx),
	}
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
