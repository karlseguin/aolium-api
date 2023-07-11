const std = @import("std");
const zqlite = @import("zqlite");
const wallz = @import("wallz.zig");
const migrations = @import("migrations/migrations.zig");

const Config = wallz.Config;

const Allocator = std.mem.Allocator;
const ValidatorPool = @import("validate").Pool;

pub const App = struct {
	config: Config,
	allocator: Allocator,
	auth_pool: zqlite.Pool,
	validators: ValidatorPool(void),

	pub fn init(allocator: Allocator, config: Config) !App{
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
			.validators = try ValidatorPool(void).init(allocator, config.validator),
		};
	}

	pub fn deinit(self: *App) void {
		self.validators.deinit();
		self.auth_pool.deinit();
	}
};
