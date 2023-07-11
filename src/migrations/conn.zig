const logz = @import("logz");
const zqlite = @import("zqlite");

// Wraps a zqlite.Conn to provide some helper functions (mostly just consistent
// logging in case of error)
pub const Conn = struct {
	conn: zqlite.Conn,
	logger: logz.Logger,
	migration_id: u32,

	pub fn begin(self: Conn) !void {
		self.logger.level(.Info).ctx("Migrate.run").int("id", self.migration_id).log();
		return self.execNoArgs("begin", "begin exclusive");
	}

	pub fn rollback(self: Conn) void {
		self.execNoArgs("rollback", "rollback") catch {};
	}

	pub fn commit(self: Conn) !void {
		return self.execNoArgs("commit", "commit");
	}

	pub fn execNoArgs(self: Conn, ctx: []const u8, sql: [:0]const u8) !void {
		self.conn.execNoArgs(sql) catch |err| {
			self.log(ctx, err, sql);
			return err;
		};
	}

	pub fn exec(self: Conn, ctx: []const u8, sql: [:0]const u8, args: anytype) !void {
		self.conn.exec(sql, args) catch |err| {
			self.log(ctx, err, sql);
			return err;
		};
	}

	pub fn row(self: Conn, ctx: []const u8, sql: [:0]const u8, args: anytype) !?zqlite.Row {
		return self.conn.row(sql, args) catch |err| {
			self.log(ctx, err, sql);
			return err;
		};
	}

	fn log(self: Conn, ctx: []const u8, err: anyerror, sql: []const u8) void {
		self.logger.level(.Error).
			ctx(ctx).
			err(err).
			stringZ("desc", self.conn.lastError()).
			string("sql", sql).
			int("id", self.migration_id).
			log();
	}
};
