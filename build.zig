const std = @import("std");

const LazyPath = std.Build.LazyPath;
const ModuleMap = std.StringArrayHashMap(*std.Build.Module);

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	var modules = ModuleMap.init(allocator);
	defer modules.deinit();

	const dep_opts = .{.target = target,.optimize = optimize};

	try modules.put("zul", b.dependency("zul", dep_opts).module("zul"));
	try modules.put("logz", b.dependency("logz", dep_opts).module("logz"));

	try modules.put("httpz", b.dependency("httpz", dep_opts).module("httpz"));
	try modules.put("cache", b.dependency("cache", dep_opts).module("cache"));
	try modules.put("typed", b.dependency("typed", dep_opts).module("typed"));
	try modules.put("validate", b.dependency("validate", dep_opts).module("validate"));

	const zqlite = b.dependency("zqlite", dep_opts).module("zqlite");
	zqlite.addCSourceFile(.{
		.file = b.path("lib/sqlite3/sqlite3.c"),
		.flags = &[_][]const u8{
			"-DSQLITE_DQS=0",
			"-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
			"-DSQLITE_USE_ALLOCA=1",
			"-DSQLITE_THREADSAFE=1",
			"-DSQLITE_TEMP_STORE=3",
			"-DSQLITE_ENABLE_API_ARMOR=1",
			"-DSQLITE_ENABLE_UNLOCK_NOTIFY",
			"-DSQLITE_ENABLE_UPDATE_DELETE_LIMIT=1",
			"-DSQLITE_DEFAULT_FILE_PERMISSIONS=0600",
			"-DSQLITE_OMIT_DECLTYPE=1",
			"-DSQLITE_OMIT_DEPRECATED=1",
			"-DSQLITE_OMIT_LOAD_EXTENSION=1",
			"-DSQLITE_OMIT_PROGRESS_CALLBACK=1",
			"-DSQLITE_OMIT_SHARED_CACHE",
			"-DSQLITE_OMIT_TRACE=1",
			"-DSQLITE_OMIT_UTF16=1",
			"-DHAVE_USLEEP=0",
		},
	});
	zqlite.addIncludePath(b.path("lib/sqlite3/"));
	try modules.put("zqlite", zqlite);

	// local libraries
	try modules.put("raw_json", b.addModule("raw_json", .{.root_source_file = .{.path = "lib/raw_json/raw_json.zig"}}));

	// setup executable
	const exe = b.addExecutable(.{
		.name = "aolium",
		.root_source_file = .{ .path = "src/main.zig" },
		.target = target,
		.optimize = optimize,
	});
	try addLibs(b, exe, modules);
	b.installArtifact(exe);

	const run_cmd = b.addRunArtifact(exe);
	run_cmd.step.dependOn(b.getInstallStep());
	if (b.args) |args| {
		run_cmd.addArgs(args);
	}

	const run_step = b.step("run", "Run the app");
	run_step.dependOn(&run_cmd.step);

	// setup tests
	const tests = b.addTest(.{
		.root_source_file = .{ .path = "src/main.zig" },
		.target = target,
		.optimize = optimize,
		.test_runner = b.path("test_runner.zig"),
	});

	try addLibs(b, tests, modules);
	const run_test = b.addRunArtifact(tests);
	run_test.has_side_effects = true;

	const test_step = b.step("test", "Run tests");
	test_step.dependOn(&run_test.step);
}

fn addLibs(b: *std.Build, step: *std.Build.Step.Compile, modules: ModuleMap) !void {
	var it = modules.iterator();
	while (it.next()) |m| {
		step.root_module.addImport(m.key_ptr.*, m.value_ptr.*);
	}

	step.linkLibC();

	step.addRPath(b.path("lib/markdown"));
	step.addLibraryPath(b.path("lib/markdown"));
	step.addIncludePath(b.path("lib/markdown"));
	step.linkSystemLibrary("cmark-gfm");
	step.linkSystemLibrary("cmark-gfm-extensions");
}
