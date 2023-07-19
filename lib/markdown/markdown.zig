const std = @import("std");
const c = @cImport(@cInclude("cmark-pondz.h"));

pub fn init() void {
	c.init();
}

pub fn toHTML(input: [:0]const u8) Result {
	return .{
		.html = c.markdown_to_html(input, input.len, 0),
	};
}

pub const Result = struct {
	html: [*:0]u8,

	pub fn deinit(self: Result) void {
		std.c.free(@ptrCast(self.html));
	}
};
