pub const Raw = struct {
	value: ?[]const u8,

	pub fn init(value: ?[]const u8) Raw {
		return .{.value = value};
	}

	pub fn jsonStringify(self: Raw, out: anytype) !void {
		const json = if (self.value) |value| value else "null";
		return out.writePreformatted(json);
	}
};

pub fn init(value: ?[]const u8) Raw {
	return Raw.init(value);
}
