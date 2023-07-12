const std = @import("std");
const logz = @import("logz");
const zqlite = @import("zqlite");

// A wrapper around zqlite.Conn with helpers and migration-specific error logging
pub const Conn = @import("conn.zig").Conn;

pub const Migration = struct {
	id: u32,
	run: *const fn(conn: Conn) anyerror!void,
};

const auth_migrations = @import("auth/migrations.zig").migrations;
const data_migrations = @import("data/migrations.zig").migrations;

// A micro-optimizations. Storing our migrations in an array means that
// we don't have to scan the array to find any missing migrations. All pending
// migrations are at: migrations[current_migration_id+1..];
// We still give migrations an id for the sake of explicitness, but the id
// is a 1-based offset of the migration in the array.

comptime {
	// make sure our migrations are in the right order
	for (auth_migrations, 0..) |m, i| {
		if (m.id != i + 1) @compileError("invalid auth migration order");
	}

	for (data_migrations, 0..) |m, i| {
		if (m.id != i + 1) @compileError("invalid data migration order");
	}
}

pub fn migrateAuth(conn: zqlite.Conn) !void {
	var logger = logz.logger().stringSafe("type", "auth").multiuse();
	defer logger.release();
	return migrate(&auth_migrations, conn, logger);
}

pub fn migrateData(conn: zqlite.Conn, shard: usize) !void {
	var logger = logz.logger().stringSafe("type", "data").int("shard", shard).multiuse();
	defer logger.release();
	return migrate(&data_migrations, conn, logger);
}

// runs any pending migration against the connection
fn migrate(migrations: []const Migration, conn: zqlite.Conn, logger: logz.Logger) !void {
	var mconn = Conn{
		.conn = conn,
		.logger = logger,
		.migration_id = 0,
	};

	try mconn.execNoArgs("Migration.migrations",
		\\ create table if not exists migrations (
		\\   id uinteger not null primary key,
		\\   created int not null default(unixepoch())
		\\ )
	);

	var installed_id: usize = 0;
	const get_installed_sql = "select id from migrations order by id desc limit 1";
	if (try mconn.row("Migration.get_intalled", get_installed_sql, .{})) |row| {
		installed_id = @intCast(row.int(0));
		row.deinit();
	}

	if (installed_id >= migrations.len) {
		// why > ? I don't know
		return;
	}

	for (migrations[installed_id..]) |migration| {
		const id = migration.id;
		mconn.migration_id = id;

		try mconn.begin();
		errdefer mconn.rollback();

		try migration.run(mconn);
		const update_migration_sql = "insert into migrations (id) values (?1)";
		try mconn.exec("migration.insert.migrations", update_migration_sql, .{id});

		try mconn.commit();
	}
}
