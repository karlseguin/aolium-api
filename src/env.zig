const logz = @import("logz");
const wallz = @import("wallz.zig");
const validate = @import("validate");

const App = wallz.App;
const User = wallz.User;

pub const Env = struct {
	app: *App,

	user: ?User = null,

	// should be loaded via the env.validator() function
	_validator: ?*validate.Context(void) = null,

	// This logger has the "$rid=REQUEST_ID" attributes (and maybe more) automatically
	// added to any generated log. Managed by the dispatcher.
	logger: logz.Logger,

	pub fn deinit(self: Env) void {
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
