const std = @import("std");
const zul = @import("zul");
const httpz = @import("httpz");
const validate = @import("validate");
const comments = @import("_comments.zig");
const posts = @import("../posts/_posts.zig");

const web = comments.web;
const aolium = web.aolium;
const Allocator = std.mem.Allocator;

pub fn handler(env: *aolium.Env, _: *httpz.Request, res: *httpz.Response) !void {
	const app = env.app;
	var sb = try app.buffers.acquire();
	defer sb.release();

	const prefix = "{\"comments\": [";
	try sb.write(prefix);
	const writer = sb.writer();

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
			const comment_value = posts.maybeRenderHTML(true, "comment", row, 2);
			defer comment_value.deinit();

			try std.json.stringify(.{
				.id = try zul.UUID.binToHex(row.blob(0), .lower),
				.name = row.nullableText(1),
				.comment = comment_value.value(),
				.post_id = try zul.UUID.binToHex(row.blob(3), .lower),
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
