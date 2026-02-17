const std = @import("std");

pub fn getValue(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

pub fn getString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const candidate = getValue(v, key) orelse return null;
    return if (candidate == .string) candidate.string else null;
}

pub fn getArray(v: std.json.Value, key: []const u8) ?std.json.Array {
    const candidate = getValue(v, key) orelse return null;
    return if (candidate == .array) candidate.array else null;
}

pub fn getInt(v: std.json.Value, key: []const u8) ?i64 {
    const candidate = getValue(v, key) orelse return null;
    return if (candidate == .integer) candidate.integer else null;
}

pub fn getFloat(v: std.json.Value, key: []const u8) ?f64 {
    const candidate = getValue(v, key) orelse return null;
    return switch (candidate) {
        .float => candidate.float,
        .integer => @as(f64, @floatFromInt(candidate.integer)),
        else => null,
    };
}
