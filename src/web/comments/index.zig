const std = @import("std");
const uuid = @import("uuid");
const httpz = @import("httpz");
const validate = @import("validate");
const comments = @import("_comments.zig");

const web = comments.web;
const aolium = web.aolium;
const Allocator = std.mem.Allocator;

pub fn handler(env: *aolium.Env, _: *httpz.Request, res: *httpz.Response) !void {
	const app = env.app;
	var sb = try app.buffers.acquireWithAllocator(res.arena);
	defer app.buffers.release(sb);

	const prefix = "{\"comments\": [";
	try sb.write(prefix);
	var writer = sb.writer();

	{
		const user = env.user.?;
		const shard_id = user.shard_id;
		const conn = app.getDataConn(shard_id);
		defer app.releaseDataConn(conn, shard_id);

		const sql =
			\\ select c.id, c.name, c.comment, c.post_id, coalesce(p.title, substr(p.text, 0, 100)), c.created
			\\ from comments c
			\\   join posts p on c.post_id = p.id
			\\ where p.user_id = ?1
			\\   and c.approved is null
			\\ order by c.created desc
			\\ limit 20
		;
		var rows = conn.rows(sql, .{user.id}) catch |err| {
			return aolium.sqliteErr("comments.select", err, conn, env.logger);
		};
		defer rows.deinit();

		while (rows.next()) |row| {
			var id_buf: [36]u8 = undefined;
			var post_id_buf: [36]u8 = undefined;

			try std.json.stringify(.{
				.id = uuid.toString(row.blob(0), &id_buf),
				.name = row.nullableText(1),
				.comment = row.text(2),
				.post_id = uuid.toString(row.blob(3), &post_id_buf),
				.post = row.text(4),
				.created = row.int(5),
			}, .{.emit_null_optional_fields = false}, writer);

			try sb.write(",\n");
		}

		if (rows.err) |err| {
			return aolium.sqliteErr("comments.select.rows", err, conn, env.logger);
		}
	}

	if (sb.len() > prefix.len) {
		//truncate the trailing ",\n"
		sb.truncate(2);
	}
	try sb.write("\n]}");

	res.body = sb.string();
	try res.write();
}
