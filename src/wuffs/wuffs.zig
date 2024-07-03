// SPDX-License-Identifier: 0BSD

const std = @import("std");

const log = std.log.scoped(.wuffs);
const Image = @import("../transform.zig").Image;

const c = @cImport({
    @cInclude("wuffs/config.h");
    @cInclude("wuffs/wuffs-v0.4.c");
});

pub fn decodePng(allocator: std.mem.Allocator, data: []const u8) !Image {
    var status: c.wuffs_base__status = undefined;

    const decoder = c.wuffs_png__decoder__alloc_as__wuffs_base__image_decoder() orelse {
        return error.WuffsError;
    };
    defer c.free(decoder);

    var src = c.wuffs_base__io_buffer{
        .data = .{
            .ptr = @constCast(data.ptr),
            .len = data.len,
        },
        .meta = .{
            .wi = data.len,
            .closed = true,
        },
    };

    var image_config: c.wuffs_base__image_config = undefined;
    status = c.wuffs_base__image_decoder__decode_image_config(decoder, &image_config, &src);
    if (!c.wuffs_base__status__is_ok(&status)) {
        log.err("wuffs: {s}", .{c.wuffs_base__status__message(&status)});
        return error.WuffsError;
    }

    const width = c.wuffs_base__pixel_config__width(&image_config.pixcfg);
    const height = c.wuffs_base__pixel_config__height(&image_config.pixcfg);
    log.debug("image dimensions: {}x{}", .{ width, height });

    c.wuffs_base__pixel_config__set(&image_config.pixcfg, c.WUFFS_BASE__PIXEL_FORMAT__BGRA_PREMUL, c.WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, width, height);

    const workbuf_len = std.math.cast(usize, c.wuffs_base__image_decoder__workbuf_len(decoder).max_incl) orelse return error.WorkbufTooLarge;
    const workbuf = try allocator.alloc(u8, workbuf_len);
    defer allocator.free(workbuf);
    log.debug("allocated workbuf: {} bytes", .{workbuf.len});

    const w_workbuf = c.wuffs_base__make_slice_u8(workbuf.ptr, workbuf.len);

    const pixbuf = try allocator.alloc(u8, width * height * 4);
    errdefer std.heap.c_allocator.free(pixbuf);
    log.debug("allocated pixbuf: {} bytes", .{pixbuf.len});

    const w_pixbuf = c.wuffs_base__make_slice_u8(pixbuf.ptr, pixbuf.len);

    var t_pixbuf: c.wuffs_base__pixel_buffer = undefined;
    status = c.wuffs_base__pixel_buffer__set_from_slice(&t_pixbuf, &image_config.pixcfg, w_pixbuf);
    if (!c.wuffs_base__status__is_ok(&status)) {
        log.err("wuffs: {s}", .{c.wuffs_base__status__message(&status)});
        return error.WuffsError;
    }

    status = c.wuffs_base__image_decoder__decode_frame(decoder, &t_pixbuf, &src, c.WUFFS_BASE__PIXEL_BLEND__SRC, w_workbuf, null);
    if (!c.wuffs_base__status__is_ok(&status)) {
        log.err("wuffs: {s}", .{c.wuffs_base__status__message(&status)});
        return error.WuffsError;
    }

    return .{
        .width = width,
        .pitch = width,
        .height = height,
        .data = pixbuf,
    };
}
