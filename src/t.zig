const std = @import("std");
const logz = @import("logz");
const uuid = @import("uuid");
const typed = @import("typed");
const validate = @import("validate");
const aolium = @import("aolium.zig");
pub const web = @import("httpz").testing;

const App = aolium.App;
const Env = aolium.Env;
const User = aolium.User;
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
pub fn expectDelta(expected: anytype, actual: @TypeOf(expected), delta: @TypeOf(expected)) !void {
	try expectEqual(true, expected - delta <= actual);
	try expectEqual(true, expected + delta >= actual);
}
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

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

	// remove any test db
	std.fs.cwd().deleteTree("tests/db") catch unreachable;
	std.fs.cwd().makePath("tests/db") catch unreachable;

	var tc = context(.{});
	defer tc.deinit();
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
		.port = 8517,
		.address = "localhost",
		.root = "tests/db",
		.log_http = false,
		.instance_id = 0,
	}) catch unreachable;

	const ctx = allocator.create(Context) catch unreachable;
	ctx.* = .{
		._env = null,
		._arena = arena,
		.arena = aa,
		.app = app,
		.web = web.init(.{}),
		.insert = Inserter.init(ctx),
	};
	return ctx;
}

pub const Context = struct {
	_arena: *std.heap.ArenaAllocator,
	_env: ?*Env,
	_user: ?User = null,
	app: *App,
	web: web.Testing,
	insert: Inserter,
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

	pub fn user(self: *Context, config: anytype) void {
		self._user = User{
			.id = config.id,
			.shard_id = 0,
		};
	}

	pub fn env(self: *Context) *Env {
		if (self._env) |e| {
			return e;
		}

		const e = allocator.create(Env) catch unreachable;
		e.* = Env{
			.app = self.app,
			.user = self._user,
			.logger = logz.logger().multiuse(),
		};
		self._env = e;
		return e;
	}

	pub fn expectInvalid(self: Context, expectation: anytype) !void {
		return validate.testing.expectInvalid(expectation, self._env.?._validator.?);
	}

	pub fn reset(self: *Context) void {
		if (self._env) |e| {
			e.deinit();
			allocator.destroy(e);
			self._env = null;
		}

		self._user = null;
		self.web.deinit();
		self.web = web.init(.{});
	}

	pub fn getAuthRow(self: Context, sql: []const u8, args: anytype) ?typed.Map {
		const conn = self.app.getAuthConn();
		defer self.app.releaseAuthConn(conn);
		return self.getRow(sql, args, conn);
	}

	pub fn getDataRow(self: Context, sql: []const u8, args: anytype) ?typed.Map {
		const conn = self.app.getDataConn(0);
		defer self.app.releaseDataConn(conn, 0);
		return self.getRow(sql, args, conn);
	}

	pub fn getRow(self: Context, sql: []const u8, args: anytype, conn: anytype) ?typed.Map {
		const row = conn.row(sql, args) catch unreachable orelse return null;
		defer row.deinit();

		const stmt = row.stmt;
		const aa = self.arena;
		const column_count: usize = @intCast(stmt.columnCount());

		var m = typed.Map.init(aa);
		for (0..column_count) |i| {
			const name = aa.dupe(u8, std.mem.span(stmt.columnName(i))) catch unreachable;
			const value = switch (stmt.columnType(i)) {
				.int => typed.Value{.i64 = row.int(i)},
				.float => typed.Value{.f64 = row.float(i)},
				.text => typed.Value{.string = aa.dupe(u8, row.text(i)) catch unreachable},
				.blob => typed.Value{.string = aa.dupe(u8, row.blob(i)) catch unreachable},
				.null => typed.Value{.null = {}},
				else => unreachable,
			};
			m.put(name, value) catch unreachable;
		}

		return m;
	}
};

// A data factory for inserting data into a tenant's instance
const Inserter = struct {
	ctx: *Context,

	fn init(ctx: *Context) Inserter {
		return .{
			.ctx = ctx,
		};
	}

	const UserParams = struct {
		username: ?[]const u8 = null,
		password: ?[]const u8 = null,
		active: bool = true,
		reset_password: bool = false,
	};

	pub fn user(self: Inserter, p: UserParams) i64 {
		const arena = self.ctx.arena;
		const argon2 =  std.crypto.pwhash.argon2;

		var buf: [300]u8 = undefined;
		const password = argon2.strHash(p.password orelse "password", .{
			.allocator = arena,
			.params = argon2.Params.fromLimits(1, 1024),
		}, &buf) catch unreachable;


		const sql =
			\\ insert or replace into users (username, password, active, reset_password)
			\\ values (?1, ?2, ?3, ?4)
		;

		const args = .{
			p.username orelse "leto",
			password,
			p.active,
			p.reset_password,
		};

		var app = self.ctx.app;
		const conn = app.getAuthConn();
		defer app.releaseAuthConn(conn);

		conn.exec(sql, args) catch {
			std.debug.print("inserter.users: {s}", .{conn.lastError()});
			unreachable;
		};

		return conn.lastInsertedRowId();
	}

	const SessionParams = struct {
		id: ?[]const u8 = null,
		user_id: ?i64 = null,
		ttl: i64 = 120,
	};

	pub fn session(self: Inserter, p: SessionParams) []const u8 {
		const arena = self.ctx.arena;
		const id = p.id orelse (uuid.allocHex(arena) catch unreachable);

		const sql =
			\\ insert into sessions (id, user_id, expires)
			\\ values (?1, ?2, unixepoch() + ?3)
		;
		const args = .{id, p.user_id orelse 0, p.ttl};

		var app = self.ctx.app;
		const conn = app.getAuthConn();
		defer app.releaseAuthConn(conn);

		conn.exec(sql, args) catch {
			std.debug.print("inserter.sessions: {s}", .{conn.lastError()});
			unreachable;
		};
		return id;
	}

	const PostParams = struct {
		user_id: i64 = 0,
		title: ?[]const u8 = null,
		text: ?[]const u8 = null,
		type: ?[]const u8 = null,
		tags: ?[]const []const u8 = null,
		created: i64 = 0,
		updated: i64 = 0,
	};

	pub fn post(self: Inserter, p: PostParams) []const u8 {
		var app = self.ctx.app;

		const user_id = p.user_id;

		const arena = self.ctx.arena;
		const id = &uuid.bin();

		var tags: ?[]const u8 = null;
		if (p.tags) |tgs| {
			tags = std.json.stringifyAlloc(arena, tgs, .{}) catch unreachable;
		}

		const sql =
			\\ insert into posts (id, user_id, title, text, type, tags, created, updated)
			\\ values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
		;
		const args = .{id, user_id, p.title, p.text orelse "", p.type orelse "simple", tags, p.created, p.updated};

		const conn = app.getDataConn(0);
		defer app.releaseDataConn(conn, 0);

		conn.exec(sql, args) catch {
			std.debug.print("inserter.posts: {s}", .{conn.lastError()});
			unreachable;
		};

		const string_id = arena.alloc(u8, 36) catch unreachable;
		return uuid.toString(id, string_id);
	}
};

fn shardIdForUserId(app: *App, user_id: i64) usize {
	const conn = app.getAuthConn();
	defer app.releaseAuthConn(conn);
	const row = conn.row("select username from users where id = ?1", .{user_id}) catch unreachable orelse return 0;
	defer row.deinit();
	return App.getShardId(row.text(0));
}
