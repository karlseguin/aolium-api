const std = @import("std");
const typed = @import("typed");
const validate = @import("validate");
pub const web = @import("../web.zig");

const pondz = web.pondz;
const Allocator = std.mem.Allocator;

// expose nested routes
pub const _index = @import("index.zig");
pub const _create = @import("create.zig");
pub const _update = @import("update.zig");

pub const index = _index.handler;
pub const create = _create.handler;
pub const update = _update.handler;

pub var create_validator: *validate.Object(void) = undefined;
var simple_validator: *validate.Object(void) = undefined;
var link_validator: *validate.Object(void) = undefined;
var long_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) !void {
	_index.init(builder);

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

pub const Post = struct {
	type: []const u8,
	text: []const u8,
	title: ?[]const u8,

	pub fn create(arena: Allocator, input: typed.Map) !Post {
		// type and text are always required
		const tpe = input.get([]u8, "type").?;
		const raw_text = normalize(input.get([]u8, "text")).?;
		const text = if (std.mem.eql(u8, tpe, "link")) try normalizeLink(arena, raw_text) else normalize(raw_text);

		return .{
			.type = tpe,
			.text = text.?,
			.title = normalize(input.get([]u8, "title")),
		};
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
};

const t = pondz.testing;
test "posts: normalize" {
	try t.expectEqual(null, Post.normalize(null));
	try t.expectEqual(null, Post.normalize(""));
	try t.expectString("value", Post.normalize("value").?);
}

test "posts: normalizeLink" {
	try t.expectEqual(null, Post.normalizeLink(undefined, null));
	try t.expectEqual(null, Post.normalizeLink(undefined, ""));
	try t.expectString("http://pondz.dev", (try Post.normalizeLink(undefined, "http://pondz.dev")).?);
	try t.expectString("HTTP://pondz.dev", (try Post.normalizeLink(undefined, "HTTP://pondz.dev")).?);
	try t.expectString("https://www.openmymind.net", (try Post.normalizeLink(undefined, "https://www.openmymind.net")).?);
	try t.expectString("HTTPS://www.openmymind.net", (try Post.normalizeLink(undefined, "HTTPS://www.openmymind.net")).?);

	{
		const link = (try Post.normalizeLink(t.allocator, "pondz.dev")).?;
		defer t.allocator.free(link);
		try t.expectString("https://pondz.dev", link);
	}
}
