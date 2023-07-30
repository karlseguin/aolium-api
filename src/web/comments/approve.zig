const std = @import("std");
const uuid = @import("uuid");
const httpz = @import("httpz");
const validate = @import("validate");
const comments = @import("_comments.zig");

const web = comments.web;
const aolium = web.aolium;

pub fn handler(env: *aolium.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const comment_id = try web.parseUUID("id", req.params.get("id").?, env);

	const user = env.user.?;
	const sql =
		\\ update comments set approved = unixepoch()
		\\ where id = ?1 and exists (
		\\   select 1 from posts where id = comments.post_id and user_id = ?2
		\\ )
		\\ and approved is null
		\\ returning post_id
	;
	const args = .{&comment_id, user.id};
	const app = env.app;

	{
		// we want conn released ASAP
		const conn = app.getDataConn(user.shard_id);
		defer app.releaseDataConn(conn, user.shard_id);

		const row = conn.row(sql, args) catch |err| {
			return aolium.sqliteErr("comments.approve", err, conn, env.logger);
		} orelse {
			return web.notFound(res, "the comment could not be found");
		};
		defer row.deinit();

		const post_id = row.text(0);
		conn.exec("update posts set comments = comments + 1 where id = ?1", .{post_id}) catch |err| {
			return aolium.sqliteErr("comments.approve.update", err, conn, env.logger);
		};
	}
	res.status = 204;
}

const t = aolium.testing;
test "posts.approve: invalid id" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 1});
	tc.web.param("id", "nope");
	try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
	try tc.expectInvalid(.{.code = validate.codes.TYPE_UUID, .field = "id"});
}

test "posts.approve: unknown id" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 1});
	tc.web.param("id", "4b0548fc-7127-438d-a87e-bc283f2d5981");
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);
}

test "posts.approve: post belongs to a different user" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 1});
	const pid = tc.insert.post(.{.user_id = 4});
	const cid = tc.insert.comment(.{.post_id = pid});

	tc.web.param("id", cid);
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);

	const row = tc.getDataRow("select 1 from comments where id = ?1", .{&(try uuid.parse(cid))});
	try t.expectEqual(true, row != null);
}

test "posts.approve: post already approved" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 20});
	const pid = tc.insert.post(.{.user_id = 20});
	const cid = tc.insert.comment(.{.post_id = pid, .approved = 10});

	tc.web.param("id", cid);
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);
}

test "posts.approve: success" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 33});
	const pid = tc.insert.post(.{.user_id = 33});
	const cid = tc.insert.comment(.{.post_id = pid, .approved = null});

	tc.web.param("id", cid);
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(204);

	const row = tc.getDataRow("select approved from comments where id = ?1", .{&(try uuid.parse(cid))}).?;
	try t.expectDelta(std.time.timestamp(), row.get(i64, "approved").?, 2);
}
