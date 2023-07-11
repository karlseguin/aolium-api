const std = @import("std");
const logz = @import("logz");
const validate = @import("validate");
const wallz = @import("wallz.zig");
const web = @import("httpz").testing;

const App = wallz.App;
const Env = wallz.Env;
const Allocator = std.mem.Allocator;
pub const allocator = std.testing.allocator;

// std.testing.expectEqual won't coerce expected to actual, which is a problem
// when expected is frequently a comptime.
// https://github.com/ziglang/zig/issues/4437
pub fn expectEqual(expected: anytype, actual: anytype) !void {
	try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}
pub fn expectContains(expected: []const u8, actual :[]const u8) !void {
	if (std.mem.indexOf(u8, actual, expected) == null) {
		std.debug.print("\nExpected string to contain '{s}'\n  Actual: {s}\n", .{expected, actual});
		return error.StringContain;
	}
}
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub fn getRandom() std.rand.DefaultPrng {
	var seed: u64 = undefined;
	std.os.getrandom(std.mem.asBytes(&seed)) catch unreachable;
	return std.rand.DefaultPrng.init(seed);
}

// We will _very_ rarely use this. Zig test doesn't have test lifecycle hooks. We
// can setup globals on startup, but we can't clean this up properly. If we use
// std.testing.allocator for these, it'll report a leak. So, we create a gpa
// without any leak reporting, and use that for the few globals that we have.
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const leaking_allocator = gpa.allocator();

pub fn noLogs() void {
	// don't use testing.allocator here because it _will_ leak, but we don't
	// care, we just need this to be available.
	logz.setup(leaking_allocator, .{.pool_size = 1, .level = .None, .output = .stderr}) catch unreachable;
}

pub fn restoreLogs() void {
	// don't use testing.allocator here because it _will_ leak, but we don't
	// care, we just need this to be available.
	logz.setup(leaking_allocator, .{.pool_size = 2, .level = .Error, .output = .stderr}) catch unreachable;
}
pub fn setup() void {
	restoreLogs();
	@import("init.zig").init(leaking_allocator) catch unreachable;
}

// Our Test.Context exists to help us write tests. It does this by:
// - Exposing the httpz.testing helpers
// - Giving us an arena for any ad-hoc allocation we need
// - Having a working *App
// - Exposing a database factory
// - Creating envs and users as needed
pub fn context(_: Context.Config) *Context {
	var arena = allocator.create(std.heap.ArenaAllocator) catch unreachable;
	arena.* = std.heap.ArenaAllocator.init(allocator);

	const aa = arena.allocator();
	const app = aa.create(App) catch unreachable;
	app.* = App.init(allocator, .{
		.root = "tests/db",
	}) catch unreachable;

	const ctx = allocator.create(Context) catch unreachable;
	ctx.* = .{
		._env = null,
		._arena = arena,
		.arena = aa,
		.app = app,
		.web = web.init(.{}),
	};
	return ctx;
}

pub const Context = struct {
	_arena: *std.heap.ArenaAllocator,
	_env: ?*Env,
	app: *App,
	web: web.Testing,
	arena: std.mem.Allocator,

	const Config = struct {
	};

	pub fn deinit(self: *Context) void {
		self.web.deinit();
		if (self._env) |e| {
			e.deinit();
			allocator.destroy(e);
		}
		self.app.deinit();

		self._arena.deinit();
		allocator.destroy(self._arena);
		allocator.destroy(self);
	}

	pub fn env(self: *Context) *Env {
		if (self._env) |e| {
			return e;
		}

		const e = allocator.create(Env) catch unreachable;
		e.* = Env{
			.app = self.app,
			.logger = logz.logger().multiuse(),
		};
		self._env = e;
		return e;
	}

	pub fn expectInvalid(self: Context, expectation: anytype) !void {
		return validate.testing.expectInvalid(expectation, self._env.?._validator.?);
	}
};
