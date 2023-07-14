const migrations = @import("migrations.zig");

const Conn = migrations.Conn;

pub fn run(conn: Conn) !void {
	try conn.execNoArgs("migration.create.users",
		\\ create table users (
		\\  id integer primary key,
		\\  username varchar not null,
		\\  email varchar null,
		\\  password varchar not null,
		\\  active bool not null,
		\\  reset_password bool not null,
		\\  created int not null default(unixepoch()),
		\\  last_login timestamptz null
		\\ )
	);

	try conn.execNoArgs("migration.create.users_index",
		\\ create unique index users_username on users (lower(username))
	);

	try conn.execNoArgs("migration.create.sessions",
		\\ create table sessions (
		\\  id varchar not null primary key,
		\\  user_id integer not null,
		\\  expires timestamptz not null,
		\\  created int not null default(unixepoch())
		\\ )
	);
}
