const std = @import("std");
const logz = @import("logz");
const cache = @import("cache");
const zqlite = @import("zqlite");
const web = @import("web/web.zig");
const pondz = @import("pondz.zig");
const migrations = @import("migrations/migrations.zig");

const User = pondz.User;
const Config = pondz.Config;

const Allocator = std.mem.Allocator;
const ValidatorPool = @import("validate").Pool;
const BufferPool = @import("string_builder").Pool;

const DATA_POOL_COUNT = if (pondz.is_test) 2 else 64;
const DATA_POOL_MASK = DATA_POOL_COUNT - 1;

pub const App = struct {
	config: Config,
	allocator: Allocator,

	// pool of sqlite connections to the auto database
	auth_pool: zqlite.Pool,

	// shard of pools
	data_pools: [DATA_POOL_COUNT]zqlite.Pool,

	// a pool of string builders
	buffers: BufferPool,

	// pool of validator, accessed through the env
	validators: ValidatorPool(void),

	// An HTTP cache
	http_cache: cache.Cache(web.CachedResponse),

	// lower(username) => User
	user_cache: cache.Cache(User),

	// session_id => User
	session_cache: cache.Cache(User),

	pub fn init(allocator: Allocator, config: Config) !App{
		// we need to generate some temporary stuff while setting up
		var arena = std.heap.ArenaAllocator.init(allocator);
		defer arena.deinit();
		const aa = arena.allocator();

		var http_cache = try cache.Cache(web.CachedResponse).init(allocator, .{
			.max_size = 524_288_000, //500mb
			.gets_per_promote = 50,
		});
		errdefer http_cache.deinit();

		var user_cache = try cache.Cache(User).init(allocator, .{
			.max_size = 1000,
			.gets_per_promote = 10,
		});
		errdefer user_cache.deinit();

		var session_cache = try cache.Cache(User).init(allocator, .{
			.max_size = 1000,
			.gets_per_promote = 10,
		});
		errdefer session_cache.deinit();

		const auth_db_path = try std.fs.path.joinZ(aa, &[_][]const u8{config.root, "auth.sqlite3"});
		var auth_pool = zqlite.Pool.init(allocator, .{
			.size = 20,
			.path = auth_db_path,
			.flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
		}) catch |err| {
			logz.fatal().ctx("app.auth_pool").err(err).string("path", auth_db_path).log();
			return err;
		};
		errdefer auth_pool.deinit();

		{
			const conn = auth_pool.acquire();
			defer auth_pool.release(conn);
			try migrations.migrateAuth(conn);
		}

		var started: usize = 0;
		var data_pools: [DATA_POOL_COUNT]zqlite.Pool = undefined;
		errdefer for (0..started) |i| data_pools[i].deinit();

		while (started < DATA_POOL_COUNT) : (started += 1) {
			const db_file = try std.fmt.allocPrint(aa, "data_{d:0>2}.sqlite3", .{started});
			const data_db_path = try std.fs.path.joinZ(aa, &[_][]const u8{config.root, db_file});
			var pool = zqlite.Pool.init(allocator, .{
				.size = 20,
				.path = data_db_path,
				.flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
			}) catch |err| {
				logz.fatal().ctx("app.data_pool").err(err).string("path", data_db_path).log();
				return err;
			};
			errdefer pool.deinit();

			{
				const conn = pool.acquire();
				defer pool.release(conn);
				try migrations.migrateData(conn, started);
			}
			data_pools[started] = pool;
		}

		return .{
			.config = config,
			.allocator = allocator,
			.auth_pool = auth_pool,
			.data_pools = data_pools,
			.http_cache = http_cache,
			.user_cache = user_cache,
			.session_cache = session_cache,
			.buffers = try BufferPool.init(allocator, 100, 500_000),
			.validators = try ValidatorPool(void).init(allocator, config.validator),
		};
	}

	pub fn deinit(self: *App) void {
		self.validators.deinit();
		self.auth_pool.deinit();
		for (&self.data_pools) |*dp| {
			dp.deinit();
		}
		self.buffers.deinit();
		self.http_cache.deinit();
		self.user_cache.deinit();
		self.session_cache.deinit();
	}

	pub fn getAuthConn(self: *App) zqlite.Conn {
		return self.auth_pool.acquire();
	}

	pub fn releaseAuthConn(self: *App, conn: zqlite.Conn) void {
		return self.auth_pool.release(conn);
	}

	pub fn getDataConn(self: *App, shard_id: usize) zqlite.Conn {
		return self.data_pools[shard_id].acquire();
	}

	pub fn releaseDataConn(self: *App, conn: zqlite.Conn, shard_id: usize) void {
		return self.data_pools[shard_id].release(conn);
	}

	pub fn getUserFromUsername(self: *App, username: []const u8) !?*cache.Entry(User) {
		var buf: [pondz.MAX_USERNAME_LEN]u8 = undefined;
		const lower = std.ascii.lowerString(&buf, username);

		if (try self.user_cache.fetch(*App, lower, loadUserFromUsername, self, .{.ttl = 1800})) |entry| {
			return entry;
		}
		return null;
	}

	// todo: either look this up or make it a consistent hash
	pub fn getShardId(username: []const u8) usize {
		var buf: [pondz.MAX_USERNAME_LEN]u8 = undefined;
		const lower = std.ascii.lowerString(&buf, username);
		const hash_code = std.hash.Wyhash.hash(0, lower);
		return hash_code & DATA_POOL_MASK;
	}


	// called on a cache miss from getUserFromUsername
	fn loadUserFromUsername(self: *App, username: []const u8) !?User {
		const sql = "select id, username from users where lower(username) = ?1 and active";
		const args = .{username};

		const conn = self.getAuthConn();
		defer self.releaseAuthConn(conn);

		const row = conn.row(sql, args) catch |err| {
			return pondz.sqliteErr("App.loadUserFromUsername", err, conn, logz.logger());
		} orelse return null;

		defer row.deinit();

		return User.init(row.int(0), row.text(1));
	}
};

const t = pondz.testing;
test "app: getShardId" {
	try t.expectEqual(App.getShardId("Leto"), App.getShardId("leto"));
	try t.expectEqual(App.getShardId("LETO"), App.getShardId("leTo"));
	try t.expectEqual(App.getShardId("Leto"), App.getShardId("LETO"));
	try t.expectEqual(false, App.getShardId("duncan") == App.getShardId("leto"));
}

test "app: getUserFromUsername" {
	var tc = t.context(.{});
	defer tc.deinit();

	const uid1 = tc.insert.user(.{.username = "Leto"});
	const uid2 = tc.insert.user(.{.username = "duncan"});
	_ = tc.insert.user(.{.username = "Piter", .active = false});

	try t.expectEqual(null, try tc.app.getUserFromUsername("Hello"));
	try t.expectEqual(null, try tc.app.getUserFromUsername("Piter"));
	try t.expectEqual(null, try tc.app.getUserFromUsername("piter"));

	{
		const ue = (try tc.app.getUserFromUsername("leto")).?;
		defer ue.release();
		try t.expectEqual(uid1, ue.value.id);
		try t.expectEqual(0, ue.value.shard_id);
	}

	{
		// ensure we get this from the cache
		const conn = tc.app.getAuthConn();
		defer tc.app.releaseAuthConn(conn);
		try conn.exec("delete from users where id = ?1", .{uid1});

		const ue = (try tc.app.getUserFromUsername("LETO")).?;
		defer ue.release();
		try t.expectEqual(uid1, ue.value.id);
		try t.expectEqual(0, ue.value.shard_id);
	}

	{
		const ue = (try tc.app.getUserFromUsername("Duncan")).?;
		defer ue.release();
		try t.expectEqual(uid2, ue.value.id);
		try t.expectEqual(1, ue.value.shard_id);
	}
}
