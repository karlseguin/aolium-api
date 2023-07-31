const std = @import("std");
const uuid = @import("uuid");
const httpz = @import("httpz");
const validate = @import("validate");
const comments = @import("_comments.zig");

const web = comments.web;
const aolium = web.aolium;
const Allocator = std.mem.Allocator;

var count_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	count_validator = builder.object(&.{
		builder.field("username", builder.string(.{.required = true, .max = aolium.MAX_USERNAME_LEN, .trim = true})),
	}, .{});
}

pub fn handler(env: *aolium.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateQuery(req, &[_][]const u8{"username"}, count_validator, env);

	const app = env.app;
	const user = try app.getUserFromUsername(input.get([]u8, "username").?) orelse {
		return web.notFound(res, "username doesn't exist");
	};

	const shard_id = user.shard_id;
	const conn = app.getDataConn(shard_id);
	defer app.releaseDataConn(conn, shard_id);

	const sql =
		\\ select count(*)
		\\ from comments c
		\\   join posts p on c.post_id = p.id
		\\ where p.user_id = ?1 and c.approved is null
	;
	var row = conn.row(sql, .{user.id}) catch |err| {
		return aolium.sqliteErr("comments.count", err, conn, env.logger);
	} orelse {
		res.body = "{\"count\":0}";
		return;
	};
	defer row.deinit();
	return res.json(.{.count = row.int(0)}, .{});
}
