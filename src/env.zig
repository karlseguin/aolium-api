const logz = @import("logz");
const cache = @import("cache");
const pondz = @import("pondz.zig");
const validate = @import("validate");

const App = pondz.App;
const User = pondz.User;

pub const Env = struct {
	// If a user is loaded, it comes from the cache, which uses reference counting
	// to release entries in a thread-safe way. The env is the owner of the cache
	// entry for the user (if we have a user).s
	_cached_user_entry: ?*cache.Entry(User) = null,

	app: *App,

	user: ?User = null,

	// should be loaded via the env.validator() function
	_validator: ?*validate.Context(void) = null,

	// This logger has the "$rid=REQUEST_ID" attributes (and maybe more) automatically
	// added to any generated log. Managed by the dispatcher.
	logger: logz.Logger,

	pub fn deinit(self: Env) void {
		self.logger.release();

		if (self._cached_user_entry) |ue| {
			ue.release();
		}

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
