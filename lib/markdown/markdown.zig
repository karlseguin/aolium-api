const std = @import("std");
const c = @cImport(@cInclude("cmark-aolium.h"));

pub fn init() void {
	c.init();
}

pub fn deinit() void {
	c.deinit();
}

pub fn toHTML(input: [*:0]const u8, len: usize) Result {
	return .{
		.value = c.markdown_to_html(input, len),
	};
}

pub const Result = struct {
	value: [*:0]u8,

	pub fn deinit(self: Result) void {
		std.c.free(@ptrCast(self.value));
	}
};
