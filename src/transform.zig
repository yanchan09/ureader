// SPDX-License-Identifier: 0BSD

const std = @import("std");

pub const Rotation = enum {
    rotation_0,
    rotation_90,
    rotation_180,
    rotation_270,

    inline fn dimensions(self: @This(), T: type, vec: [2]T) [2]T {
        return switch (self) {
            .rotation_0 => .{ vec[0], vec[1] },
            .rotation_90 => .{ vec[1], vec[0] },
            .rotation_180 => .{ vec[0], vec[1] },
            .rotation_270 => .{ vec[1], vec[0] },
        };
    }

    inline fn inv_apply(self: @This(), T: type, vec: [2]T, bounds: [2]T) [2]T {
        return switch (self) {
            .rotation_0 => .{ vec[0], vec[1] },
            .rotation_90 => .{ vec[1], bounds[1] - 1 - vec[0] },
            .rotation_180 => .{ bounds[0] - 1 - vec[0], bounds[1] - 1 - vec[1] },
            .rotation_270 => .{ bounds[0] - 1 - vec[1], vec[0] },
        };
    }
};

pub const Image = struct {
    width: u32,
    height: u32,
    pitch: u32,
    data: []u8,

    inline fn setPixel(self: *@This(), pos: [2]u32, value: [4]u8) void {
        const base = (self.pitch * pos[1] + pos[0]) * 4;
        @memcpy(self.data[base .. base + 4], &value);
    }

    inline fn getPixel(self: *const @This(), pos: [2]u32) [4]u8 {
        const base = (self.pitch * pos[1] + pos[0]) * 4;
        return self.data[base .. base + 4][0..4].*;
    }
};

pub fn transformTo(dst: *Image, src: *const Image, rotation: Rotation) void {
    @setCold(true);
    switch (rotation) {
        .rotation_0 => transform0(dst, src),
        .rotation_90 => transformToInternal(dst, src, .rotation_90),
        .rotation_180 => transformToInternal(dst, src, .rotation_180),
        .rotation_270 => transform270(dst, src),
    }
}

inline fn transform0(dst: *Image, src: *const Image) void {
    std.debug.assert(dst.width == src.width);
    std.debug.assert(dst.height == src.height);

    var dst_pos: usize = 0;
    var src_pos: usize = 0;
    const row_width = dst.width * 4;
    for (0..dst.height) |_| {
        @memcpy(dst.data[dst_pos .. dst_pos + row_width], src.data[src_pos .. src_pos + row_width]);
        dst_pos += dst.pitch * 4;
        src_pos += src.pitch * 4;
    }
}

const MASK_16 = ~@as(u32, 0b1111);
const MASK_8 = ~@as(u32, 0b111);
const MASK_4 = ~@as(u32, 0b11);
const MASK_2 = ~@as(u32, 0b1);

inline fn transform270(dst: *Image, src: *const Image) void {
    std.debug.assert(dst.width == src.height);
    std.debug.assert(dst.height == src.width);

    const dst_blank = dst.pitch - dst.width;
    const src_next_row = src.pitch * 4;

    var dst_pos: usize = 0;
    var src_start: usize = src.width * 4;
    for (0..dst.height) |_| {
        src_start -= 4;
        var src_pos = src_start;
        var i: u32 = 0;
        while (i < dst.width & MASK_4) {
            inline for (0..4) |_| {
                @memcpy(dst.data[dst_pos .. dst_pos + 4], src.data[src_pos .. src_pos + 4]);
                dst_pos += 4;
                src_pos += src_next_row;
            }
            i += 4;
        }
        switch (dst.width & 0b11) {
            3 => {
                inline for (0..3) |_| {
                    @memcpy(dst.data[dst_pos .. dst_pos + 4], src.data[src_pos .. src_pos + 4]);
                    dst_pos += 4;
                    src_pos += src_next_row;
                }
            },
            2 => {
                inline for (0..2) |_| {
                    @memcpy(dst.data[dst_pos .. dst_pos + 4], src.data[src_pos .. src_pos + 4]);
                    dst_pos += 4;
                    src_pos += src_next_row;
                }
            },
            1 => {
                @memcpy(dst.data[dst_pos .. dst_pos + 4], src.data[src_pos .. src_pos + 4]);
                dst_pos += 4;
                src_pos += src_next_row;
            },
            0 => {},
            else => unreachable,
        }
        dst_pos += dst_blank;
    }
}

inline fn transformToInternal(dst: *Image, src: *const Image, comptime rotation: Rotation) void {
    const expected_dims = rotation.dimensions(u32, .{ src.width, src.height });
    std.debug.assert(dst.width == expected_dims[0]);
    std.debug.assert(dst.height == expected_dims[1]);

    for (0..dst.height) |y| {
        const MASK = ~@as(u32, 0b1111);
        var x: usize = 0;
        while (x < dst.width & MASK) {
            inline for (0..16) |i| {
                const src_pos = rotation.inv_apply(u32, .{ @intCast(x + i), @intCast(y) }, .{ src.width, src.height });
                dst.setPixel(.{ @intCast(x + i), @intCast(y) }, src.getPixel(src_pos));
            }
            x += 16;
        }
        while (x < dst.width) {
            const src_pos = rotation.inv_apply(u32, .{ @intCast(x), @intCast(y) }, .{ src.width, src.height });
            dst.setPixel(.{ @intCast(x), @intCast(y) }, src.getPixel(src_pos));
            x += 1;
        }
    }
}

test "transformTo - 0deg" {
    var src_data = [_]u8{
        0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
        4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7,
    };
    var dst_data: [32]u8 = undefined;
    const src = Image{ .width = 4, .height = 2, .pitch = 4, .data = &src_data };
    var dst = Image{ .width = 4, .height = 2, .pitch = 4, .data = &dst_data };

    transformTo(&dst, &src, .rotation_0);
    std.debug.print("{any}\n{any}\n", .{ src_data, dst_data });
    try std.testing.expect(std.mem.eql(u8, &src_data, &dst_data));
}

test "transformTo - 90deg" {
    var src_data = [_]u8{
        0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
        4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7,
    };
    var dst_data: [32]u8 = undefined;
    const src = Image{ .width = 4, .height = 2, .pitch = 4, .data = &src_data };
    var dst = Image{ .width = 2, .height = 4, .pitch = 2, .data = &dst_data };

    transformTo(&dst, &src, .rotation_90);

    const expected = [_]u8{
        4, 4, 4, 4, 0, 0, 0, 0,
        5, 5, 5, 5, 1, 1, 1, 1,
        6, 6, 6, 6, 2, 2, 2, 2,
        7, 7, 7, 7, 3, 3, 3, 3,
    };
    try std.testing.expect(std.mem.eql(u8, &dst_data, &expected));
}

test "transformTo - 180deg" {
    var src_data = [_]u8{
        0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
        4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7,
    };
    var dst_data: [32]u8 = undefined;
    const src = Image{ .width = 4, .height = 2, .pitch = 4, .data = &src_data };
    var dst = Image{ .width = 4, .height = 2, .pitch = 4, .data = &dst_data };

    transformTo(&dst, &src, .rotation_180);
    const expected = [_]u8{
        7, 7, 7, 7, 6, 6, 6, 6, 5, 5, 5, 5, 4, 4, 4, 4,
        3, 3, 3, 3, 2, 2, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0,
    };
    try std.testing.expect(std.mem.eql(u8, &dst_data, &expected));
}

test "transformTo - 270deg" {
    var src_data = [_]u8{
        0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
        4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7,
    };
    var dst_data: [32]u8 = undefined;
    const src = Image{ .width = 4, .height = 2, .pitch = 4, .data = &src_data };
    var dst = Image{ .width = 2, .height = 4, .pitch = 2, .data = &dst_data };

    transformTo(&dst, &src, .rotation_270);

    const expected = [_]u8{
        3, 3, 3, 3, 7, 7, 7, 7,
        2, 2, 2, 2, 6, 6, 6, 6,
        1, 1, 1, 1, 5, 5, 5, 5,
        0, 0, 0, 0, 4, 4, 4, 4,
    };
    try std.testing.expect(std.mem.eql(u8, &dst_data, &expected));
}
