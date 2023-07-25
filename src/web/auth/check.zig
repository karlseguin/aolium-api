const std = @import("std");
const httpz = @import("httpz");
const auth = @import("_auth.zig");

const web = auth.web;
const aolium = web.aolium;

pub fn handler(_: *aolium.Env, _: *httpz.Request, res: *httpz.Response) !void {
	// Can only get here if we got past the dispatcher
	res.status = 204;
}
