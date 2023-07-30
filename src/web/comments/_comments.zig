const std = @import("std");
const validate = @import("validate");
pub const web = @import("../web.zig");

const aolium = web.aolium;
const Allocator = std.mem.Allocator;

// expose nested routes
pub const _index = @import("index.zig");
pub const _create = @import("create.zig");
pub const _delete = @import("delete.zig");
pub const _approve = @import("approve.zig");
pub const index = _index.handler;
pub const create = _create.handler;
pub const delete = _delete.handler;
pub const approve = _approve.handler;

pub var create_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) !void {
	_create.init(builder);
}
