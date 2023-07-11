const logz = @import("logz");
const wallz = @import("wallz.zig");
const validate = @import("validate");

pub const Env = struct {
	app: *wallz.App,

	// This logger has the "$rid=REQUEST_ID" attributes (and maybe more) automatically
	// added to any generated log.
	logger: logz.Logger,

	_validator: ?*validate.Context(void) = null,

	pub fn deinit(self: Env) void {
		self.logger.release();
		if (self._validator) |val| {
			self.app.validators.release(val);
		}
	}

	pub fn validator(self: *Env) !*validate.Context(void) {
		if (self._validator) |val| {
			return val;
		}

		const val = try self.app.validators.acquire({});
		self._validator = val;
		return val;
	}
};
