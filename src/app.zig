const std = @import("std");
const wallz = @import("wallz.zig");

const Config = wallz.Config;

const Allocator = std.mem.Allocator;
const ValidatorPool = @import("validate").Pool;

pub const App = struct {
	config: Config,
	allocator: Allocator,
	validators: ValidatorPool(void),

	pub fn init(allocator: Allocator, config: Config) !App{
		return .{
			.config = config,
			.allocator = allocator,
			.validators = try ValidatorPool(void).init(allocator, config.validator),
		};
	}

	pub fn deinit(self: *App) void {
		self.validators.deinit();
	}
};
