const std = @import("std");
const logz = @import("logz");
const cache = @import("cache");
const zqlite = @import("zqlite");
const web = @import("web/web.zig");
const aolium = @import("aolium.zig");
const migrations = @import("migrations/migrations.zig");

const User = aolium.User;
const Config = aolium.Config;

const Allocator = std.mem.Allocator;
const ValidatorPool = @import("validate").Pool;
const BufferPool = @import("buffer").Pool;

const DATA_POOL_COUNT = if (aolium.is_test) 1 else 64;
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

	pub fn getUserFromUsername(self: *App, username: []const u8) !?User {
		var buf: [aolium.MAX_USERNAME_LEN]u8 = undefined;
		const lower = std.ascii.lowerString(&buf, username);

		const entry = (try self.user_cache.fetch(*App, lower, loadUserFromUsername, self, .{.ttl = 1800})) orelse {
			return null;
		};

		// entry "owns" the user, but user can safely be copied (it's just a couple ints)
		const user = entry.value;
		entry.release();
		return user;
	}

	// todo: either look this up or make it a consistent hash
	pub fn getShardId(username: []const u8) usize {
		var buf: [aolium.MAX_USERNAME_LEN]u8 = undefined;
		const lower = std.ascii.lowerString(&buf, username);
		const hash_code = std.hash.Wyhash.hash(0, lower);
		return hash_code & DATA_POOL_MASK;
	}

	pub fn clearUserCache(self: *App, user_id: i64) void {
		// TODO: delPrefix tries to minize write locks, but it's still an O(N) on the
		// cache, this has to switch to be switched to layered cache at some point.
		_ = self.http_cache.delPrefix(std.mem.asBytes(&user_id)) catch |err| {
			logz.err().ctx("app.clearUserCache").err(err).int("user_id", user_id).log();
		};
	}

	pub fn clearPostCache(self: *App, post_id: []const u8) void {
		// TODO: delPrefix tries to minize write locks, but it's still an O(N) on the
		// cache, this has to switch to be switched to layered cache at some point.
		_ = self.http_cache.delPrefix(post_id) catch |err| {
			logz.err().ctx("app.clearPostCache").err(err).binary("post_id", post_id).log();
		};
	}

	// called on a cache miss from getUserFromUsername
	fn loadUserFromUsername(self: *App, username: []const u8) !?User {
		const sql = "select id, username from users where lower(username) = ?1 and active";
		const args = .{username};

		const conn = self.getAuthConn();
		defer self.releaseAuthConn(conn);

		const row = conn.row(sql, args) catch |err| {
			return aolium.sqliteErr("App.loadUserFromUsername", err, conn, logz.logger());
		} orelse return null;

		defer row.deinit();

		return try User.init(self.user_cache.allocator, row.int(0), row.text(1));
	}
};

const t = aolium.testing;
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
		const user = (try tc.app.getUserFromUsername("leto")).?;
		try t.expectEqual(uid1, user.id);
		try t.expectEqual(0, user.shard_id);
	}

	{
		// ensure we get this from the cache
		const conn = tc.app.getAuthConn();
		defer tc.app.releaseAuthConn(conn);
		try conn.exec("delete from users where id = ?1", .{uid1});

		const user = (try tc.app.getUserFromUsername("LETO")).?;
		try t.expectEqual(uid1, user.id);
		try t.expectEqual(0, user.shard_id);
	}

	{
		const user = (try tc.app.getUserFromUsername("Duncan")).?;
		try t.expectEqual(uid2, user.id);
		try t.expectEqual(0, user.shard_id);
	}
}
