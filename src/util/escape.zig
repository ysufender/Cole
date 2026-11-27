const std = @import("std");

pub const EscapeError = error{
    OutOfMemory,
    UnknownEscape,
    InvalidHexEscape,
};

pub fn unescape(allocator: std.mem.Allocator, raw: []const u8) EscapeError![]const u8 {
    if (std.mem.findScalar(u8, raw, '\\') == null) return raw;

    const out = try allocator.alloc(u8, raw.len);

    var r: usize = 0;
    var w: usize = 0;
    while (r < raw.len) : (w += 1) {
        const c = raw[r];
        r += 1;

        if (c != '\\') {
            out[w] = c;
            continue;
        }

        if (r == raw.len) return EscapeError.UnknownEscape;

        const e = raw[r];
        r += 1;

        out[w] = switch (e) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '0' => 0,
            '\\' => '\\',
            '\'' => '\'',
            '"' => '"',
            'x' => hex: {
                if (r + 2 > raw.len) return EscapeError.InvalidHexEscape;
                const hi = std.fmt.charToDigit(raw[r], 16) catch return EscapeError.InvalidHexEscape;
                const lo = std.fmt.charToDigit(raw[r + 1], 16) catch return EscapeError.InvalidHexEscape;
                r += 2;
                break :hex (hi << 4) | lo;
            },
            else => return EscapeError.UnknownEscape,
        };
    }

    return out[0..w];
}
