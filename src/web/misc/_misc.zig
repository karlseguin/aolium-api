const std = @import("std");
const httpz = @import("httpz");
const web = @import("../web.zig");

const aolium = web.aolium;

pub fn ping(env: *aolium.Env, _: *httpz.Request, res: *httpz.Response) !void {
	const app = env.app;
	const shard_id = @as(usize, @intCast(std.time.timestamp())) % app.data_pools.len;
	const conn = app.getDataConn(shard_id);
	defer app.releaseDataConn(conn, shard_id);

	const row = conn.row("select 1", .{}) catch |err| {
		return aolium.sqliteErr("ping.select", err, conn, env.logger);
	} orelse return error.PingSelectError;
	defer row.deinit();

	res.body = try std.fmt.allocPrint(res.arena, "db: {d}", .{row.int(0)});
}
