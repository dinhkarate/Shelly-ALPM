//! ANSI/VT escape sequence parsing for console output.
//!
//! Messages forwarded from pacman, makepkg, and package scriptlets can
//! carry terminal escape codes. `Parser` splits text into styled segments
//! so the transaction console can render colors instead of printing the
//! raw sequences. Non-SGR sequences (cursor movement, OSC hyperlinks, and
//! the like) and control characters are stripped. This module is display
//! independent so it can be tested without GTK.

const std = @import("std");

/// Standard 16-color xterm palette used by SGR codes 30-37, 90-97, and
/// their 40-47/100-107 background variants.
pub const base_palette = [16]u24{
    0x000000, 0xcd0000, 0x00cd00, 0xcdcd00,
    0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
    0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00,
    0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
};

/// Resolves a 256-color index (SGR `38;5;n` / `48;5;n`) to RGB using the
/// standard xterm color cube and grayscale ramp.
pub fn palette256(index: u8) u24 {
    if (index < 16) return base_palette[index];
    if (index < 232) {
        const steps = [6]u8{ 0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff };
        const value = index - 16;
        const red: u24 = steps[value / 36];
        const green: u24 = steps[(value % 36) / 6];
        const blue: u24 = steps[value % 6];
        return (red << 16) | (green << 8) | blue;
    }
    const level: u24 = 8 + (@as(u24, index) - 232) * 10;
    return (level << 16) | (level << 8) | level;
}

/// Text style accumulated from SGR sequences. Colors are packed RGB;
/// `null` means the terminal default so theme styling stays in charge.
pub const Style = struct {
    fg: ?u24 = null,
    bg: ?u24 = null,
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,

    /// Packs the style into a collision-free u64 key for tag caches.
    pub fn bits(self: Style) u64 {
        var value: u64 = 0;
        if (self.fg) |color| {
            value |= @as(u64, color);
            value |= @as(u64, 1) << 24;
        }
        if (self.bg) |color| {
            value |= @as(u64, color) << 25;
            value |= @as(u64, 1) << 49;
        }
        if (self.bold) value |= @as(u64, 1) << 50;
        if (self.faint) value |= @as(u64, 1) << 51;
        if (self.italic) value |= @as(u64, 1) << 52;
        if (self.underline) value |= @as(u64, 1) << 53;
        if (self.reverse) value |= @as(u64, 1) << 54;
        if (self.strikethrough) value |= @as(u64, 1) << 55;
        return value;
    }

    pub fn isDefault(self: Style) bool {
        return self.bits() == 0;
    }
};

/// A run of text that shares one style.
pub const Segment = struct {
    text: []const u8,
    style: Style,
};

/// Splits input into styled segments. Style state persists across lines
/// within one message, matching terminal semantics; each message starts
/// from the default style.
pub const Parser = struct {
    input: []const u8,
    index: usize = 0,
    style: Style = .{},
    segment_start: usize = 0,
    segment_style: Style = .{},

    pub fn init(input: []const u8) Parser {
        return .{ .input = input };
    }

    pub fn next(self: *Parser) ?Segment {
        while (self.index < self.input.len) {
            const current = self.input[self.index];
            if (current == 0x1b) {
                const segment_end = self.index;
                self.consumeEscape();
                if (segment_end > self.segment_start) {
                    const segment = Segment{
                        .text = self.input[self.segment_start..segment_end],
                        .style = self.segment_style,
                    };
                    self.segment_start = self.index;
                    self.segment_style = self.style;
                    return segment;
                }
                self.segment_start = self.index;
                self.segment_style = self.style;
                continue;
            }
            if (isStrippedControl(current)) {
                if (self.index > self.segment_start) {
                    const segment = Segment{
                        .text = self.input[self.segment_start..self.index],
                        .style = self.segment_style,
                    };
                    self.segment_start = self.index;
                    return segment;
                }
                self.index += 1;
                self.segment_start = self.index;
                continue;
            }
            self.index += 1;
        }
        if (self.index > self.segment_start) {
            const segment = Segment{
                .text = self.input[self.segment_start..self.index],
                .style = self.segment_style,
            };
            self.segment_start = self.index;
            return segment;
        }
        return null;
    }

    fn consumeEscape(self: *Parser) void {
        std.debug.assert(self.input[self.index] == 0x1b);
        const rest = self.input[self.index + 1 ..];
        if (rest.len == 0) {
            self.index = self.input.len;
            return;
        }
        switch (rest[0]) {
            '[' => {
                var end = self.index + 2;
                while (end < self.input.len and !isCsiFinal(self.input[end])) end += 1;
                if (end >= self.input.len) {
                    self.index = self.input.len;
                    return;
                }
                if (self.input[end] == 'm') self.applySgr(self.input[self.index + 2 .. end]);
                self.index = end + 1;
            },
            ']' => {
                var end = self.index + 2;
                while (end < self.input.len) : (end += 1) {
                    if (self.input[end] == 0x07) {
                        self.index = end + 1;
                        return;
                    }
                    if (self.input[end] == 0x1b and end + 1 < self.input.len and
                        self.input[end + 1] == '\\')
                    {
                        self.index = end + 2;
                        return;
                    }
                }
                self.index = self.input.len;
            },
            else => {
                const designates_charset = rest[0] == '(' or rest[0] == ')' or
                    rest[0] == '*' or rest[0] == '+';
                const width: usize = if (designates_charset) 3 else 2;
                self.index += @min(width, self.input.len - self.index);
            },
        }
    }

    fn applySgr(self: *Parser, params: []const u8) void {
        var values: [16]u16 = undefined;
        var count: usize = 0;
        if (params.len == 0) {
            values[0] = 0;
            count = 1;
        } else {
            var tokens = std.mem.tokenizeAny(u8, params, ";:");
            while (tokens.next()) |token| {
                if (count == values.len) break;
                values[count] = std.fmt.parseInt(u16, token, 10) catch 0;
                count += 1;
            }
        }

        var i: usize = 0;
        while (i < count) : (i += 1) {
            switch (values[i]) {
                0 => self.style = .{},
                1 => self.style.bold = true,
                2 => self.style.faint = true,
                3 => self.style.italic = true,
                4 => self.style.underline = true,
                7 => self.style.reverse = true,
                9 => self.style.strikethrough = true,
                21 => self.style.underline = true,
                22 => {
                    self.style.bold = false;
                    self.style.faint = false;
                },
                23 => self.style.italic = false,
                24 => self.style.underline = false,
                27 => self.style.reverse = false,
                29 => self.style.strikethrough = false,
                30...37 => self.style.fg = base_palette[values[i] - 30],
                38, 48 => |kind| {
                    if (i + 1 >= count) continue;
                    const is_foreground = kind == 38;
                    switch (values[i + 1]) {
                        5 => if (i + 2 < count) {
                            self.setColor(is_foreground, palette256(@intCast(@min(values[i + 2], 255))));
                            i += 2;
                        },
                        2 => if (i + 4 < count) {
                            const red: u24 = @intCast(@min(values[i + 2], 255));
                            const green: u24 = @intCast(@min(values[i + 3], 255));
                            const blue: u24 = @intCast(@min(values[i + 4], 255));
                            self.setColor(is_foreground, (red << 16) | (green << 8) | blue);
                            i += 4;
                        },
                        else => {},
                    }
                },
                39 => self.style.fg = null,
                40...47 => self.style.bg = base_palette[values[i] - 40],
                49 => self.style.bg = null,
                90...97 => self.style.fg = base_palette[values[i] - 90 + 8],
                100...107 => self.style.bg = base_palette[values[i] - 100 + 8],
                else => {},
            }
        }
    }

    fn setColor(self: *Parser, is_foreground: bool, color: u24) void {
        if (is_foreground) self.style.fg = color else self.style.bg = color;
    }
};

fn isCsiFinal(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x7e;
}

fn isStrippedControl(byte: u8) bool {
    if (byte == '\t' or byte == '\n') return false;
    return byte < 0x20 or byte == 0x7f;
}

/// Removes all escape sequences and stripped control characters, keeping
/// the visible text. Allocation proportional to `text`; the caller owns
/// the result.
pub fn strip(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var buffer = try alloc.alloc(u8, text.len);
    defer alloc.free(buffer);
    var parser = Parser.init(text);
    var length: usize = 0;
    while (parser.next()) |segment| {
        @memcpy(buffer[length..][0..segment.text.len], segment.text);
        length += segment.text.len;
    }
    return alloc.dupe(u8, buffer[0..length]);
}

/// Strips escape sequences into `buf`, truncating only if the visible
/// text cannot fit, and returns a slice of `buf`.
pub fn stripInto(buf: []u8, text: []const u8) []const u8 {
    var parser = Parser.init(text);
    var length: usize = 0;
    while (parser.next()) |segment| {
        const take = @min(segment.text.len, buf.len - length);
        if (take == 0) break;
        @memcpy(buf[length..][0..take], segment.text[0..take]);
        length += take;
    }
    return buf[0..length];
}

const testing = std.testing;

test "palette256 matches the xterm cube and grayscale ramp" {
    try testing.expectEqual(@as(u24, 0x000000), palette256(0));
    try testing.expectEqual(@as(u24, 0xcd0000), palette256(1));
    try testing.expectEqual(@as(u24, 0xff0000), palette256(9));
    try testing.expectEqual(@as(u24, 0xffffff), palette256(15));
    try testing.expectEqual(@as(u24, 0xff0000), palette256(196));
    try testing.expectEqual(@as(u24, 0x5f87af), palette256(67));
    try testing.expectEqual(@as(u24, 0x080808), palette256(232));
    try testing.expectEqual(@as(u24, 0xeeeeee), palette256(255));
}

test "parser renders sgr colors and attributes as styled segments" {
    var parser = Parser.init("\x1b[32mgreen\x1b[0m and \x1b[1;94mbright blue bold\x1b[22m");
    const green = parser.next().?;
    try testing.expectEqualStrings("green", green.text);
    try testing.expectEqual(@as(?u24, 0x00cd00), green.style.fg);

    const plain = parser.next().?;
    try testing.expectEqualStrings(" and ", plain.text);
    try testing.expect(plain.style.isDefault());

    const blue = parser.next().?;
    try testing.expectEqualStrings("bright blue bold", blue.text);
    try testing.expectEqual(@as(?u24, 0x5c5cff), blue.style.fg);
    try testing.expect(blue.style.bold);

    try testing.expect(parser.next() == null);
}

test "parser applies background, 256-color, and truecolor codes" {
    var parser = Parser.init("\x1b[41mred bg\x1b[49m\x1b[38;5;196mred fg\x1b[39m\x1b[48;2;10;20;30mbg truecolor");
    const red_bg = parser.next().?;
    try testing.expectEqual(@as(?u24, 0xcd0000), red_bg.style.bg);
    try testing.expectEqual(@as(?u24, null), red_bg.style.fg);

    const red_fg = parser.next().?;
    try testing.expectEqualStrings("red fg", red_fg.text);
    try testing.expectEqual(@as(?u24, 0xff0000), red_fg.style.fg);
    try testing.expectEqual(@as(?u24, null), red_fg.style.bg);

    const truecolor = parser.next().?;
    try testing.expectEqualStrings("bg truecolor", truecolor.text);
    try testing.expectEqual(@as(?u24, 0x0a141e), truecolor.style.bg);
    try testing.expectEqual(@as(?u24, null), truecolor.style.fg);
}

test "parser accepts colon separated color subparameters" {
    var parser = Parser.init("\x1b[38:2:255:128:0;1mmodern truecolor bold");
    const segment = parser.next().?;
    try testing.expectEqual(@as(?u24, 0xff8000), segment.style.fg);
    try testing.expect(segment.style.bold);
}

test "parser strips cursor, erase, and OSC sequences" {
    var parser = Parser.init("\x1b[2K\x1b[1Aafter cursor \x1b]0;window title\x07done\x1b(B!");
    var text: [64]u8 = undefined;
    var length: usize = 0;
    while (parser.next()) |segment| {
        @memcpy(text[length..][0..segment.text.len], segment.text);
        length += segment.text.len;
    }
    try testing.expectEqualStrings("after cursor done!", text[0..length]);
}

test "parser drops truncated trailing sequences" {
    var parser = Parser.init("output\x1b[3");
    const segment = parser.next().?;
    try testing.expectEqualStrings("output", segment.text);
    try testing.expect(parser.next() == null);

    parser = Parser.init("visible\x1b]0;unfinished");
    const osc = parser.next().?;
    try testing.expectEqualStrings("visible", osc.text);
    try testing.expect(parser.next() == null);
}

test "parser keeps tabs and newlines but strips other controls" {
    var parser = Parser.init("a\r\tb\n\x07c\x7fd");
    var text: [64]u8 = undefined;
    var length: usize = 0;
    while (parser.next()) |segment| {
        @memcpy(text[length..][0..segment.text.len], segment.text);
        length += segment.text.len;
    }
    try testing.expectEqualStrings("a\tb\ncd", text[0..length]);
}

test "parser carries style across newlines within one message" {
    var parser = Parser.init("\x1b[33mfirst\nsecond\x1b[0m plain");
    const styled = parser.next().?;
    try testing.expectEqualStrings("first\nsecond", styled.text);
    try testing.expectEqual(@as(?u24, 0xcdcd00), styled.style.fg);

    const plain = parser.next().?;
    try testing.expectEqualStrings(" plain", plain.text);
    try testing.expect(plain.style.isDefault());
}

test "parser leaves plain text untouched" {
    var parser = Parser.init("resolving dependencies...");
    const segment = parser.next().?;
    try testing.expectEqualStrings("resolving dependencies...", segment.text);
    try testing.expect(segment.style.isDefault());
    try testing.expect(parser.next() == null);
}

test "style bits form distinct cache keys" {
    try testing.expect((Style{}).isDefault());
    try testing.expectEqual(@as(u64, 0), (Style{}).bits());

    const fg: Style = .{ .fg = 0x00cd00 };
    const bg: Style = .{ .bg = 0x00cd00 };
    try testing.expect(!fg.isDefault());
    try testing.expect(fg.bits() != bg.bits());
    try testing.expect(fg.bits() != (Style{ .fg = 0x00cd01 }).bits());
    try testing.expectEqual(@as(u64, 0xffffff | (@as(u64, 1) << 24)), (Style{ .fg = 0xffffff }).bits());
}

test "strip removes escape codes and keeps visible text" {
    const stripped = try strip(testing.allocator, "\x1b[1;32m::\x1b[0m \x1b[1mRunning pre-install hooks\x1b[0m\x1b[?2026h");
    defer testing.allocator.free(stripped);
    try testing.expectEqualStrings(":: Running pre-install hooks", stripped);

    const plain = try strip(testing.allocator, "no escapes here");
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("no escapes here", plain);
}

test "stripInto writes visible text into the caller buffer" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(
        "Progress 50%",
        stripInto(&buf, "\x1b[1;33mProgress\x1b[0m \x1b[32m50%\x1b[0m"),
    );

    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("Progress"[0..4], stripInto(&small, "\x1b[1mProgress 50%"));
}
