const std = @import("std");
const cache = @import("cache");
const zqlite = @import("zqlite");
const wallz = @import("wallz.zig");
const migrations = @import("migrations/migrations.zig");

const User = wallz.User;
const Config = wallz.Config;

const Allocator = std.mem.Allocator;
const ValidatorPool = @import("validate").Pool;

const DATA_POOL_COUNT = if (wallz.is_test) 2 else 64;
const DATA_POOL_MASK = DATA_POOL_COUNT - 1;

pub const App = struct {
	config: Config,
	allocator: Allocator,

	// pool of sqlite connections to the auto database
	auth_pool: zqlite.Pool,

	// shard of pools
	data_pools: [DATA_POOL_COUNT]zqlite.Pool,

	// pool of validator, accessed through the env
	validators: ValidatorPool(void),

	// A cache for session tokens
	session_cache: cache.Cache(User),

	pub fn init(allocator: Allocator, config: Config) !App{
		// we need to generate some temporary stuff while setting up
		var arena = std.heap.ArenaAllocator.init(allocator);
		defer arena.deinit();
		const aa = arena.allocator();

		var session_cache = try cache.Cache(User).init(allocator, .{
			.max_size = 1000,
			.gets_per_promote = 10,
		});
		errdefer session_cache.deinit();

		var auth_pool = try zqlite.Pool.init(allocator, .{
			.size = 20,
			.path = try std.fs.path.joinZ(aa, &[_][]const u8{config.root, "auth.sqlite3"}),
			.flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
		});
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
			var pool = try zqlite.Pool.init(allocator, .{
				.size = 20,
				.path = try std.fs.path.joinZ(aa, &[_][]const u8{config.root, db_file}),
				.flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
			});
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
			.session_cache = session_cache,
			.validators = try ValidatorPool(void).init(allocator, config.validator),
		};
	}

	pub fn deinit(self: *App) void {
		self.validators.deinit();
		self.auth_pool.deinit();
		for (&self.data_pools) |*dp| {
			dp.deinit();
		}
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

	// todo: either look this up or make it a consistent hash
	pub fn getShardId(username: []const u8) usize {
		var buf: [wallz.MAX_USERNAME_LEN]u8 = undefined;
		const lower = std.ascii.lowerString(&buf, username);
		const hash_code = std.hash.Wyhash.hash(0, lower);
		return hash_code & DATA_POOL_MASK;
	}
};

const t = wallz.testing;
test "app: getShardId" {
	try t.expectEqual(App.getShardId("Leto"), App.getShardId("leto"));
	try t.expectEqual(App.getShardId("LETO"), App.getShardId("leTo"));
	try t.expectEqual(App.getShardId("Leto"), App.getShardId("LETO"));
	try t.expectEqual(false, App.getShardId("Duncan") == App.getShardId("leto"));
}
