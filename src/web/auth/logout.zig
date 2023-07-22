const std = @import("std");
const httpz = @import("httpz");
const auth = @import("_auth.zig");

const web = auth.web;
const aolium = web.aolium;

pub fn handler(env: *aolium.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const sql = "delete from sessions where id = ?1";
	const args = .{web.getSessionId(req)};

	const app = env.app;
	const conn = app.getAuthConn();
	defer app.releaseAuthConn(conn);

	conn.exec(sql, args) catch |err| {
		return aolium.sqliteErr("login.select", err, conn, env.logger);
	};
	res.status = 204;
}

const t = aolium.testing;

test "auth.logout" {
	var tc = t.context(.{});
	defer tc.deinit();

	const sid1 = tc.insert.session(.{});
	const sid2 = tc.insert.session(.{});

	{
		// unknown session_id is no-op
		tc.web.header("authorization", "aolium nope");
		try handler(tc.env(), tc.web.req, tc.web.res);
		try tc.web.expectStatus(204);
	}

	{
		// valid
		tc.reset();
		tc.web.header("authorization", try std.fmt.allocPrint(tc.arena, "aolium {s}", .{sid1}));
		try handler(tc.env(), tc.web.req, tc.web.res);
		try tc.web.expectStatus(204);

		{
			const row = tc.getAuthRow("select * from sessions where id = ?1", .{sid1});
			try t.expectEqual(null, row);
		}

		{
			const row = tc.getAuthRow("select 1 from sessions where id = ?1", .{sid2});
			try t.expectEqual(true, row != null);
		}
	}
}
