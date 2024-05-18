const std = @import("std");
const zul = @import("zul");
const logz = @import("logz");
const httpz = @import("httpz");
const aolium = @import("aolium.zig");

const App = aolium.App;
const Config = aolium.Config;
const Allocator = std.mem.Allocator;

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	// Some data exists for the entire lifetime of the project. We could just
	// use the gpa allocator, but if we don't properly clean it up, it'll cause
	// tests to report leaks.
	var arena = std.heap.ArenaAllocator.init(allocator);
	defer arena.deinit();
	const aa = arena.allocator();

	const config = try parseArgs(aa);
	try logz.setup(allocator, config.logger);
	defer logz.deinit();

	try @import("init.zig").init(aa);
	defer @import("init.zig").deinit();

	logz.info().ctx("init").
		string("db_root", config.root).
		boolean("log_http", config.log_http).
		stringSafe("log_level", @tagName(logz.level())).
		log();

	var app = try App.init(allocator, config);
	defer app.deinit();
	try @import("web/web.zig").start(&app);
}

fn parseArgs(allocator: Allocator) !Config {
	var args = try zul.CommandLineArgs.parse(allocator);
	defer args.deinit();

	const stdout = std.io.getStdOut().writer();

	if (args.contains("version")) {
		try std.io.getStdOut().writer().print("{s}", .{aolium.version});
		std.process.exit(0);
	}

	var port: u16 = 8517;
	var address: []const u8 = "127.0.0.1";
	var instance_id: u8 = 0;
	var log_level = logz.Level.Info;
	var cors: ?httpz.Config.CORS = null;

	const log_http = args.contains("log_http");

	if (args.get("port")) |value| {
		port = std.fmt.parseInt(u16, value, 10) catch {
			try stdout.print("port must be a positive integer\n", .{});
			std.process.exit(2);
		};
	}

	if (args.get("address")) |value| {
		address = try allocator.dupe(u8, value);
	}

	if (args.get("log_level")) |value| {
		log_level = logz.Level.parse(value) orelse {
			try stdout.print("invalid log_level value\n", .{});
			std.process.exit(2);
		};
	}

	if (args.get("instance_id")) |value| {
		instance_id = std.fmt.parseInt(u8, value, 10) catch {
			try stdout.print("instance_id must be an integer between 0 and 255r\n", .{});
			std.process.exit(2);
		};
	}

	if (args.get("cors")) |value| {
		cors = httpz.Config.CORS{
			.origin = try allocator.dupe(u8, value),
			.max_age = "7200",
			.headers = "content-type,authorization",
			.methods = "GET,POST,PUT,DELETE",
		};
	}

	var root: [:0]u8 = undefined;
	const path = args.get("root") orelse "db/";
	if (std.fs.path.isAbsolute(path)) {
		root = try allocator.dupeZ(u8, path);
	} else {
		var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
		const cwd = try std.posix.getcwd(&buffer);
		root = try std.fs.path.joinZ(allocator, &[_][]const u8{cwd, path});
	}

	try std.fs.cwd().makePath(root);

	return .{
		.root = root,
		.port = port,
		.cors = cors,
		.address = address,
		.log_http = log_http,
		.instance_id = instance_id,
		.logger = .{.level = log_level},

	};
}

const t = aolium.testing;
test {
	t.setup();
	std.testing.refAllDecls(@This());
}
