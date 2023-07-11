const std = @import("std");
const cache = @import("cache");
const zqlite = @import("zqlite");
const wallz = @import("wallz.zig");
const migrations = @import("migrations/migrations.zig");

const User = wallz.User;
const Config = wallz.Config;

const Allocator = std.mem.Allocator;
const ValidatorPool = @import("validate").Pool;

pub const App = struct {
	config: Config,
	allocator: Allocator,

	// pool of sqlite connections to the auto database
	auth_pool: zqlite.Pool,

	// pool of validator, accessed through the env
	validators: ValidatorPool(void),

	// A cache for session tokens
	session_cache: cache.Cache(User),

	pub fn init(allocator: Allocator, config: Config) !App{
		var session_cache = try cache.Cache(User).init(allocator, .{
			.max_size = 1000,
			.gets_per_promote = 10,
		});
		errdefer session_cache.deinit();

		const auth_db_path = try std.fs.path.joinZ(allocator, &[_][]const u8{config.root, "auth.sqlite3"});
		defer allocator.free(auth_db_path);

		var auth_pool = try zqlite.Pool.init(allocator, .{
			.size = 20,
			.path = auth_db_path,
			.flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
		});
		errdefer auth_pool.deinit();

		{
			const auth_conn = auth_pool.acquire();
			defer auth_pool.release(auth_conn);
			try migrations.migrateAuth(auth_conn);
		}

		return .{
			.config = config,
			.allocator = allocator,
			.auth_pool = auth_pool,
			.session_cache = session_cache,
			.validators = try ValidatorPool(void).init(allocator, config.validator),
		};
	}

	pub fn deinit(self: *App) void {
		self.validators.deinit();
		self.auth_pool.deinit();
		self.session_cache.deinit();
	}

	pub fn getAuthConn(self: *App) zqlite.Conn {
		return self.auth_pool.acquire();
	}

	pub fn releaseAuthConn(self: *App, conn: zqlite.Conn) void {
		return self.auth_pool.release(conn);
	}
};
