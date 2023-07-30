const std = @import("std");
const validate = @import("validate");
const markdown = @import("markdown");

// There's no facility to do initialization on startup (like Go's init), so
// we'll just hard-code this ourselves. The reason we extract this out is
// largely so that our tests can call this (done when a test context is created)
pub fn init(aa: std.mem.Allocator) !void {
	markdown.init();

	const builder = try aa.create(validate.Builder(void));
	builder.* = try validate.Builder(void).init(aa);
	try @import("web/auth/_auth.zig").init(builder);
	try @import("web/posts/_posts.zig").init(builder);
	try @import("web/comments/_comments.zig").init(builder);
}
