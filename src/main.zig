const std = @import("std");
const logz = @import("logz");
const wallz = @import("wallz.zig");

const App = wallz.App;
const Config = wallz.Config;
const Allocator = std.mem.Allocator;

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	var config_file: ?[]const u8 = null;
	var it = try std.process.argsWithAllocator(allocator);
	_ = it.next(); // skip executable
	if (it.next()) |arg| {
		config_file = arg;
	}
	it.deinit();

	// Some data exists for the entire lifetime of the project. We could just
	// use the gpa allocator, but if we don't properly clean it up, it'll cause
	// tests to report leaks.
	var arena = std.heap.ArenaAllocator.init(allocator);
	defer arena.deinit();
	const aa = arena.allocator();

	const config = try parseArgs(aa);
	try logz.setup(allocator, config.logger);
	try @import("init.zig").init(aa);

	logz.info().ctx("Log.setup").
		stringSafe("level", @tagName(logz.level())).
		boolean("http_log", config.log_http).
		string("note", "alter via logger.level=LEVEL and log_http=BOOL flags").
		log();

	var app = try App.init(allocator, config);
	try @import("web/web.zig").start(&app);
}

fn parseArgs(allocator: Allocator) !wallz.Config {
	const yazap = @import("yazap");

	var app = yazap.App.init(allocator, "wallz", "A wallz server");

	var cmd = app.rootCommand();
	try cmd.addArg(yazap.Arg.booleanOption("version", 'v', "Print the version and exit"));
	try cmd.addArg(yazap.Arg.booleanOption("log_http", null, "Log http requests"));
	try cmd.addArg(yazap.Arg.singleValueOption("port", null, "Port to listen on (default: 6667)"));
	try cmd.addArg(yazap.Arg.singleValueOption("instance_id", null, "If running multiple instances, giving each one a unique instance_id will improve the uniqueness of request_id (default: 0)"));
	try cmd.addArg(yazap.Arg.singleValueOption("address", null, "Address to bind to (default: 127.0.0.1)"));
	try cmd.addArg(yazap.Arg.singleValueOptionWithValidValues("log_level", null, "Log level to use (default: INFO), see also log_http)", &[_][]const u8{"info", "warn", "error", "fatal", "none"}));

	const stdout = std.io.getStdOut().writer();
	const args = app.parseProcess() catch {
		try stdout.print("Use ircz --help to list available arguments\n", .{});
		std.os.exit(1);
	};

	if (args.containsArg("version")) {
		try std.io.getStdOut().writer().print("{s}", .{wallz.version});
		std.os.exit(0);
	}

	var port: u16 = 8517;
	var address: []const u8 = "127.0.0.1";
	var instance_id: u8 = 0;
	var log_level = logz.Level.Info;
	const log_http = args.containsArg("log_http");

	if (args.getSingleValue("port")) |value| {
		port = std.fmt.parseInt(u16, value, 10) catch {
			try stdout.print("port must be a positive integer\n", .{});
			std.os.exit(2);
		};
	}

	if (args.getSingleValue("address")) |value| {
		address = value;
	}

	if (args.getSingleValue("log_level")) |value| {
		log_level = logz.Level.parse(value) orelse {
			try stdout.print("invalid log_level value\n", .{});
			std.os.exit(2);
		};
	}

	if (args.getSingleValue("instance_id")) |value| {
		instance_id = std.fmt.parseInt(u8, value, 10) catch {
			try stdout.print("instance_id must be an integer between 0 and 255r\n", .{});
			std.os.exit(2);
		};
	}

	return .{
		.port = port,
		.address = address,
		.log_http = log_http,
		.instance_id = instance_id,
		.logger = .{.level = log_level},
	};
}

const t = wallz.testing;
test {
	t.setup();
	std.testing.refAllDecls(@This());
}
