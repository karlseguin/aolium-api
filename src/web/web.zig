const std = @import("std");
const logz = @import("logz");
const httpz = @import("httpz");
const typed = @import("typed");
const validate = @import("validate");
pub const wallz = @import("../wallz.zig");

const App = wallz.App;
const Env = wallz.Env;
const Allocator = std.mem.Allocator;
const Dispatcher = @import("dispatcher.zig").Dispatcher;

// handlers
const auth = @import("auth/_auth.zig");

pub fn start(app: *App) !void {
	const config = app.config;
	const allocator = app.allocator;

	var server = try httpz.ServerCtx(*const Dispatcher, *Env).init(allocator, .{
		.port = config.port,
		.address = config.address,
	}, undefined);
	server.notFound(routerNotFound);
	server.errorHandler(errorHandler);
	server.dispatcher(Dispatcher.dispatch);

	const router = server.router();
	var routes = router.group("/", .{.ctx = &Dispatcher{
		.app = app,
		.log_http = config.log_http,
	}});
	routes.post("/auth/login", auth.login);

	var http_address = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{config.address, config.port});
	logz.info().ctx("http").string("address", http_address).log();
	allocator.free(http_address);

	// blocks
	try server.listen();
}

// Since our dispatcher handles action errors, this should not happen unless
// the dispatcher itself, or the underlying http framework, fails.
fn errorHandler(_: *const Dispatcher, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
	const code = errors.ServerError.write(res);
	logz.err().err(err).ctx("errorHandler").string("path", req.url.raw).int("code", code).log();
}

// Not found specifically related to the method/path, this is passed to our
// http framework as a fallback.
fn routerNotFound(_: *const Dispatcher, _: *httpz.Request, res: *httpz.Response) !void {
	_ = errors.RouterNotFound.write(res);
}

// An application-level 404, e.g. a call to DELETE /blah/:id and the :id wasn't
// found. Always nice to include a brief description of exactly what wasn't found
// to help developers.
pub fn notFound(res: *httpz.Response, desc: []const u8) !void {
	res.status = 404;
	return res.json(.{
		.desc = desc,
		.err = "not found",
		.code = wallz.codes.NOT_FOUND,
	}, .{});
}

pub fn validateJson(req: *httpz.Request, v: *validate.Object(void), env: *Env) !typed.Map {
	const body = (try req.body()) orelse return error.InvalidJson;

	var validator = try env.validator();
	const input = try v.validateJsonS(body, validator);
	if (!validator.isValid()) {
		return error.Validation;
	}
	return input;
}

// pre-generated error messages
pub const Error = struct {
	code: i32,
	status: u16,
	body: []const u8,

	fn init(status: u16, comptime code: i32, comptime message: []const u8) Error {
		const body = std.fmt.comptimePrint("{{\"code\": {d}, \"err\": \"{s}\"}}", .{code, message});
		return .{
			.code = code,
			.body = body,
			.status = status,
		};
	}

	pub fn write(self: Error, res: *httpz.Response) i32 {
		res.status = self.status;
		res.content_type = httpz.ContentType.JSON;
		res.body = self.body;
		return self.code;
	}
};

// bunch of static errors that we can serialize at comptime
pub const errors = struct {
	const codes = wallz.codes;
	pub const ServerError = Error.init(500, codes.INTERNAL_SERVER_ERROR_UNCAUGHT, "internal server error");
	pub const RouterNotFound = Error.init(404, codes.ROUTER_NOT_FOUND, "not found");
	pub const InvalidJson = Error.init(400, codes.INVALID_JSON, "invalid JSON");
	pub const InvalidAuthorization = Error.init(401, codes.INVALID_AUTHORIZATION, "invalid authorization");
	pub const ExpiredSessionId = Error.init(401, codes.EXPIRED_SESSION_ID, "expired session id");
};

const t = wallz.testing;
test "web: Error.write" {
	var tc = t.context(.{});
	defer tc.deinit();

	try t.expectEqual(0, errors.ServerError.write(tc.web.res));
	try tc.web.expectStatus(500);
	try tc.web.expectJson(.{.code = 0, .err = "internal server error"});
}

test "web: notFound" {
	var tc = t.context(.{});
	defer tc.deinit();

	try notFound(tc.web.res, "no spice");
	try tc.web.expectStatus(404);
	try tc.web.expectJson(.{.code = 3, .err = "not found", .desc = "no spice"});
}
