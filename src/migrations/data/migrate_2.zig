const migrations = @import("migrations.zig");

const Conn = migrations.Conn;

pub fn run(conn: Conn) !void {
	try conn.execNoArgs("migration.create.comments",
		\\ create table comments (
		\\  id blob primary key,
		\\  post_id blog not null,
		\\  user_id integer null,
		\\  name text null,
		\\  comment text not null,
		\\  created int not null default(unixepoch()),
		\\  approved int null
		\\ )
	);

	try conn.execNoArgs("migration.create.comments_post_id_index",
		\\ create index comments_post_id on comments(post_id)
	);

	try conn.execNoArgs("migration.comment_count.posts",
		\\ alter table posts add column comments int not null default(0)
	);

	try conn.execNoArgs("migration.create.posts_user_id_index",
		\\ create index posts_user_id on posts(user_id, created desc)
	);
}
