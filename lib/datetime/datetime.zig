const std = @import("std");

pub const DateTime = struct {
	year: u16,
	month: u8,
	day: u8,
	hour: u8,
	minute: u8,
	second: u8,

	pub fn toRFC3339(self: DateTime) [20]u8 {
		var buf: [20]u8 = undefined;
		_ = std.fmt.formatIntBuf(buf[0..4], self.year, 10, .lower, .{.width = 4, .fill = '0'});
		buf[4] = '-';
		paddingTwoDigits(buf[5..7], self.month);
		buf[7] = '-';
		paddingTwoDigits(buf[8..10], self.day);
		buf[10] = 'T';

		paddingTwoDigits(buf[11..13], self.hour);
		buf[13] = ':';
		paddingTwoDigits(buf[14..16], self.minute);
		buf[16] = ':';
		paddingTwoDigits(buf[17..19], self.second);
		buf[19] = 'Z';

		return buf;
	}
};

pub fn fromTimestamp(ts: u64) DateTime {
	const SECONDS_PER_DAY = 86400;
	const DAYS_PER_YEAR = 365;
	const DAYS_IN_4YEARS = 1461;
	const DAYS_IN_100YEARS = 36524;
	const DAYS_IN_400YEARS = 146097;
	const DAYS_BEFORE_EPOCH = 719468;

	const seconds_since_midnight: u64 = @rem(ts, SECONDS_PER_DAY);
	var day_n: u64 = DAYS_BEFORE_EPOCH + ts / SECONDS_PER_DAY;
	var temp: u64 = 0;

	temp = 4 * (day_n + DAYS_IN_100YEARS + 1) / DAYS_IN_400YEARS - 1;
	var year: u16 = @intCast(100 * temp);
	day_n -= DAYS_IN_100YEARS * temp + temp / 4;

	temp = 4 * (day_n + DAYS_PER_YEAR + 1) / DAYS_IN_4YEARS - 1;
	year += @intCast(temp);
	day_n -= DAYS_PER_YEAR * temp + temp / 4;

	var month: u8 = @intCast((5 * day_n + 2) / 153);
	const day: u8 = @intCast(day_n - (@as(u64, @intCast(month)) * 153 + 2) / 5 + 1);

	month += 3;
	if (month > 12) {
		month -= 12;
		year += 1;
	}

	return .{
		.year = year,
		.month = month,
		.day = day,
		.hour = @intCast(seconds_since_midnight / 3600),
		.minute = @intCast(seconds_since_midnight % 3600 / 60),
		.second = @intCast(seconds_since_midnight % 60)
	};
}

fn paddingTwoDigits(buf: *[2]u8, value: u8) void {
	switch (value) {
		0 => buf.* = "00".*,
		1 => buf.* = "01".*,
		2 => buf.* = "02".*,
		3 => buf.* = "03".*,
		4 => buf.* = "04".*,
		5 => buf.* = "05".*,
		6 => buf.* = "06".*,
		7 => buf.* = "07".*,
		8 => buf.* = "08".*,
		9 => buf.* = "09".*,
		10 => buf.* = "10".*,
		11 => buf.* = "11".*,
		12 => buf.* = "12".*,
		13 => buf.* = "13".*,
		14 => buf.* = "14".*,
		15 => buf.* = "15".*,
		16 => buf.* = "16".*,
		17 => buf.* = "17".*,
		18 => buf.* = "18".*,
		19 => buf.* = "19".*,
		20 => buf.* = "20".*,
		21 => buf.* = "21".*,
		22 => buf.* = "22".*,
		23 => buf.* = "23".*,
		24 => buf.* = "24".*,
		25 => buf.* = "25".*,
		26 => buf.* = "26".*,
		27 => buf.* = "27".*,
		28 => buf.* = "28".*,
		29 => buf.* = "29".*,
		30 => buf.* = "30".*,
		31 => buf.* = "31".*,
		32 => buf.* = "32".*,
		33 => buf.* = "33".*,
		34 => buf.* = "34".*,
		35 => buf.* = "35".*,
		36 => buf.* = "36".*,
		37 => buf.* = "37".*,
		38 => buf.* = "38".*,
		39 => buf.* = "39".*,
		40 => buf.* = "40".*,
		41 => buf.* = "41".*,
		42 => buf.* = "42".*,
		43 => buf.* = "43".*,
		44 => buf.* = "44".*,
		45 => buf.* = "45".*,
		46 => buf.* = "46".*,
		47 => buf.* = "47".*,
		48 => buf.* = "48".*,
		49 => buf.* = "49".*,
		50 => buf.* = "50".*,
		51 => buf.* = "51".*,
		52 => buf.* = "52".*,
		53 => buf.* = "53".*,
		54 => buf.* = "54".*,
		55 => buf.* = "55".*,
		56 => buf.* = "56".*,
		57 => buf.* = "57".*,
		58 => buf.* = "58".*,
		59 => buf.* = "59".*,
		else => _ = std.fmt.formatIntBuf(buf, value, 10, .lower, .{}),
	}
}
