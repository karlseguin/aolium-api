const std = @import("std");
const validate = @import("validate");

// There's no facility to do initialization on startup (like Go's init), so
// we'll just hard-code this ourselves. The reason we extract this out is
// largely so that our tests can call this (done when a test context is created)
pub fn init(aa: std.mem.Allocator) !void {
	const builder = try aa.create(validate.Builder(void));
	builder.* = try validate.Builder(void).init(aa);
	try @import("web/auth/_auth.zig").init(builder);
}
