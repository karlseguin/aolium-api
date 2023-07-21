const migrations = @import("migrations.zig");

const Conn = migrations.Conn;

pub fn run(conn: Conn) !void {
	try conn.execNoArgs("migration.create.posts",
		\\ create table posts (
		\\  id blob primary key,
		\\  user_id integer not null,
		\\  title text null,
		\\  text text not null,
		\\  tags text null,
		\\  type text not null,
		\\  created int not null default(unixepoch()),
		\\  updated int not null default(unixepoch())
		\\ )
	);
}
