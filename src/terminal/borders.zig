//! Experimental cell borders. The DCS identifier is provisional, not registered.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const reply = "\x1bP1+bghostty-border;ok\x1b\\";
pub const Stroke = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    width: u6 = 0, // Zero means absent; otherwise 1/256 of cell width.
    centered: bool = false,
    above: bool = false,
};
pub const Set = [12]Stroke;
pub const empty: Set = @splat(.{});

/// IDs are stable for the terminal lifetime. This prototype does not reclaim
/// styles; the bounded table costs nothing until the first border is painted.
pub const Store = struct {
    sets: std.ArrayList(Set) = .empty,
    ids: std.AutoHashMapUnmanaged(Set, u16) = .empty,

    pub fn deinit(self: *Store, alloc: Allocator) void {
        self.sets.deinit(alloc);
        self.ids.deinit(alloc);
    }

    pub fn get(self: *const Store, id: u16) Set {
        return if (id == 0 or id > self.sets.items.len) empty else self.sets.items[id - 1];
    }

    pub fn intern(self: *Store, alloc: Allocator, value: Set) !u16 {
        if (std.meta.eql(value, empty)) return 0;
        if (self.ids.get(value)) |id| return id;
        if (self.sets.items.len == std.math.maxInt(u16)) return error.BorderStyleLimit;
        try self.sets.ensureUnusedCapacity(alloc, 1);
        try self.ids.ensureUnusedCapacity(alloc, 1);
        const id: u16 = @intCast(self.sets.items.len + 1);
        self.sets.appendAssumeCapacity(value);
        self.ids.putAssumeCapacity(value, id);
        return id;
    }
};

pub const Request = union(enum) {
    query,
    paint: struct {
        mask: u12,
        stroke: Stroke, // An absent stroke clears the selected segments.
        rows: u16,
        cols: u16,
    },
};

pub const Buffer = struct {
    data: [256]u8 = undefined,
    len: usize = 0,

    pub fn append(self: *Buffer, byte: u8) !void {
        if (self.len == self.data.len) return error.CommandTooLong;
        self.data[self.len] = byte;
        self.len += 1;
    }
};

fn decimal(value: []const u8, max: u16) ?u16 {
    if (value.len == 0) return null;
    for (value) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u16, value, 10) catch return null;
    return if (n <= max) n else null;
}

pub fn parse(body: []const u8) ?Request {
    var fields = std.mem.splitScalar(u8, body, ';');
    if (!std.mem.eql(u8, fields.next() orelse return null, "ghostty-border")) return null;
    const op = fields.next() orelse return null;
    if (std.mem.eql(u8, op, "q")) return if (fields.next() == null) .query else null;
    const clear = std.mem.eql(u8, op, "clear");
    if (!clear and !std.mem.eql(u8, op, "set")) return null;
    const mask = decimal(fields.next() orelse return null, 4095) orelse return null;
    if (mask == 0) return null;
    var stroke: Stroke = .{};
    if (!clear) {
        const width = decimal(fields.next() orelse return null, 32) orelse return null;
        if (width == 0) return null;
        const rgb = fields.next() orelse return null;
        if (rgb.len != 6) return null;
        for (rgb) |c| if (!std.ascii.isHex(c)) return null;
        const color = std.fmt.parseInt(u24, rgb, 16) catch return null;
        const placement = decimal(fields.next() orelse return null, 1) orelse return null;
        const layer = decimal(fields.next() orelse return null, 1) orelse return null;
        stroke = .{
            .r = @truncate(color >> 16),
            .g = @truncate(color >> 8),
            .b = @truncate(color),
            .width = @intCast(width),
            .centered = placement == 1,
            .above = layer == 1,
        };
    }
    const rows = decimal(fields.next() orelse return null, 65535) orelse return null;
    const cols = decimal(fields.next() orelse return null, 65535) orelse return null;
    if (rows == 0 or cols == 0 or fields.next() != null) return null;
    return .{ .paint = .{ .mask = @intCast(mask), .stroke = stroke, .rows = rows, .cols = cols } };
}

/// Pixel geometry, relative to the owning cell. Segments meet at the rounded
/// center, overlapping the central stroke square to avoid gaps at corners.
pub fn rectangle(index: usize, stroke: Stroke, width: u32, height: u32) [4]i32 {
    const w: i32 = @intCast(width);
    const h: i32 = @intCast(height);
    const t: i32 = @intCast(@max(1, (width * @as(u32, stroke.width) + 128) / 256));
    const cx = @divTrunc(w, 2);
    const cy = @divTrunc(h, 2);
    const half = @divTrunc(t, 2);
    const inset: i32 = if (stroke.centered) -half else 0;
    return switch (index) {
        0 => .{ 0, inset, cx + t - half, t },
        1 => .{ cx - half, inset, w - cx + half, t },
        2 => .{ w - t - inset, 0, t, cy + t - half },
        3 => .{ w - t - inset, cy - half, t, h - cy + half },
        4 => .{ 0, h - t - inset, cx + t - half, t },
        5 => .{ cx - half, h - t - inset, w - cx + half, t },
        6 => .{ inset, 0, t, cy + t - half },
        7 => .{ inset, cy - half, t, h - cy + half },
        8 => .{ 0, cy - half, cx + t - half, t },
        9 => .{ cx - half, cy - half, w - cx + half, t },
        10 => .{ cx - half, 0, t, cy + t - half },
        11 => .{ cx - half, cy - half, t, h - cy + half },
        else => unreachable,
    };
}

test "borders parse and independent half segments" {
    const testing = std.testing;
    const req = parse("ghostty-border;set;3;16;80c5b7;0;1;1;20").?.paint;
    try testing.expectEqual(@as(u12, 3), req.mask);
    try testing.expectEqual(@as(u8, 0x80), req.stroke.r);
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    var value = empty;
    value[0] = req.stroke;
    value[1] = req.stroke;
    const full = try store.intern(testing.allocator, value);
    value[0] = .{};
    const half = try store.intern(testing.allocator, value);
    try testing.expect(full != half);
    try testing.expectEqual(req.stroke, store.get(half)[1]);
    try testing.expectEqual(full, try store.intern(testing.allocator, store.get(full)));
    try testing.expectEqual(@as(u16, 0), try store.intern(testing.allocator, empty));
    for ([_][]const u8{
        "ghostty-border;set;3;0;80c5b7;0;1;1;20",
        "ghostty-border;clear;4096;1;1",
        "ghostty-border;clear;1;0;1",
        "ghostty-border;clear;+1;1;1",
        "ghostty-border;q;extra",
        "ghostty-border;set;1;16;xxxxxx;0;1;1;1",
    }) |bad| try testing.expect(parse(bad) == null);
}

test "borders geometry uses equal thickness and joins half arms" {
    const testing = std.testing;
    const stroke: Stroke = .{ .width = 32 };
    const horizontal = rectangle(9, stroke, 16, 32);
    const vertical = rectangle(11, stroke, 16, 32);
    try testing.expectEqual(horizontal[3], vertical[2]);
    try testing.expectEqual(horizontal[0], vertical[0]);
    try testing.expectEqual(horizontal[1], vertical[1]);
}
