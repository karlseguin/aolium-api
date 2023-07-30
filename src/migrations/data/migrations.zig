const m = @import("../migrations.zig");

pub const Conn = m.Conn;

pub const migrations = [_]m.Migration{
	.{.id = 1, .run = &(@import("migrate_1.zig").run)},
	.{.id = 2, .run = &(@import("migrate_2.zig").run)},
};
