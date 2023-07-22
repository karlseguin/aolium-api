const std = @import("std");
const typed = @import("typed");
const zqlite = @import("zqlite");
const markdown = @import("markdown");
const validate = @import("validate");
pub const web = @import("../web.zig");

const aolium = web.aolium;
const Allocator = std.mem.Allocator;

// expose nested routes
pub const _index = @import("index.zig");
pub const _show = @import("show.zig");
pub const _create = @import("create.zig");
pub const _update = @import("update.zig");

pub const index = _index.handler;
pub const show = _show.handler;
pub const create = _create.handler;
pub const update = _update.handler;

pub var create_validator: *validate.Object(void) = undefined;
var simple_validator: *validate.Object(void) = undefined;
var link_validator: *validate.Object(void) = undefined;
var long_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) !void {
	_index.init(builder);
	_show.init(builder);

	const tag_validator = builder.string(.{.trim = true, .max = 20});

	create_validator = builder.object(&.{
		builder.field("type", builder.string(.{.required = true, .choices = &.{"simple", "link", "long"}})),
		builder.field("tags", builder.array(tag_validator, .{.max = 10})),
	}, .{.function = validatePost});

	simple_validator = builder.object(&.{
		builder.field("text", builder.string(.{.required = true, .max = 500, .trim = true})),
	}, .{});

	link_validator = builder.object(&.{
		builder.field("title", builder.string(.{.required = true, .max = 200, .trim = true})),
		builder.field("text", builder.string(.{.required = true, .max = 200, .trim = true})),
	}, .{});

	long_validator = builder.object(&.{
		builder.field("title", builder.string(.{.required = true, .max = 200, .trim = true})),
		builder.field("text", builder.string(.{.required = true, .max = 5000, .trim = true})),
	}, .{});
}

pub const Post = struct {
	type: []const u8,
	text: []const u8,
	title: ?[]const u8,
	tags: ?[]const u8,  // serialized JSON array

	pub fn create(arena: Allocator, input: typed.Map) !Post {
		// type and text are always required
		const tpe = input.get([]u8, "type").?;
		var text = input.get([]u8, "text");
		if (std.mem.eql(u8, tpe, "link")) {
			text = try normalizeLink(arena, text.?);
		}

		var tags: ?[]const u8 = null;
		if (input.get(typed.Array, "tags")) |tgs| {
			tags = try std.json.stringifyAlloc(arena, tgs.items, .{});
		}

		return .{
			.type = tpe,
			.text = text.?,
			.tags = tags,
			.title = input.get([]u8, "title"),
		};
	}


	// we know allocator is an arena
	fn normalizeLink(allocator: std.mem.Allocator, link: []const u8) ![]const u8 {
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

// Wraps a nullable text column which may be raw or may be rendered html from
// markdown. This wrapper allows our caller to call .value() and .deinit()
// without having to know anything.
pub const RenderResult = union(enum) {
	raw: ?[]const u8,
	html: markdown.Result,

	pub fn value(self: RenderResult) ?[]const u8 {
		return switch (self) {
			.raw => |v| v,
			.html => |html| std.mem.span(html.value),
		};
	}

	pub fn deinit(self: RenderResult) void {
		switch (self) {
			.raw => {},
			.html => |html| html.deinit(),
		}
	}
};

// We optionally render markdown to HTML. If we _don't_, then things are
// straightforward and we return the text column from sqlite as-is.
// However, if we _are_ rendering, we (a) need a null-terminated string
// from sqlite (because that's what cmark wants) and we need to free the
// result.
pub fn maybeRenderHTML(html: bool, tpe: []const u8, row: zqlite.Row, col: usize) RenderResult {
	if (!html or std.mem.eql(u8, tpe, "link")) {
		return .{.raw = row.nullableText(col)};
	}

	const value = row.nullableTextZ(col) orelse {
		return .{.raw = null};
	};

	// we're here because we've been asked to render the value to HTML and
	// we actually have a value
	return .{.html = markdown.toHTML(value, row.textLen(col))};
}

const t = aolium.testing;
test "posts: normalizeLink" {
	try t.expectString("http://aolium.dev", try Post.normalizeLink(undefined, "http://aolium.dev"));
	try t.expectString("HTTP://aolium.dev", try Post.normalizeLink(undefined, "HTTP://aolium.dev"));
	try t.expectString("https://www.openmymind.net", try Post.normalizeLink(undefined, "https://www.openmymind.net"));
	try t.expectString("HTTPS://www.openmymind.net", try Post.normalizeLink(undefined, "HTTPS://www.openmymind.net"));

	{
		const link = try Post.normalizeLink(t.allocator, "aolium.dev");
		defer t.allocator.free(link);
		try t.expectString("https://aolium.dev", link);
	}
}
