// SPDX-License-Identifier: 0BSD

pub const std_options = std.Options{
    .log_level = .debug,
};

const std = @import("std");
const wuffs = @import("./wuffs/wuffs.zig");
const libDrm = @import("./drm.zig");
const transform = @import("./transform.zig");

const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
    @cInclude("drm_fourcc.h");
    @cInclude("omap_drmif.h");
});

pub fn main() !void {
    var timer = try std.time.Timer.start();
    const image = try wuffs.decodePng(std.heap.c_allocator, @embedFile("example0d.png"));
    std.log.info("Image decode took {}ms", .{@as(f32, @floatFromInt(timer.lap())) / std.time.ns_per_ms});

    const drm = try libDrm.DrmHandle.open("/dev/dri/card0");
    defer drm.close();

    const connector = try drm.findConnector();
    defer connector.deinit();

    std.log.info("Using connector {}", .{connector});

    const crtc = try drm.findCrtc(connector);

    std.log.info("Using CRTC {}", .{crtc});

    const plane = try drm.findPrimaryPlane(crtc);

    std.log.info("Using {} as primary plane", .{plane});

    const fb = try createFramebuffer(drm, image);

    {
        const at = try drm.newAtomic();
        defer at.deinit();

        const disp_w: u64 = @intCast(connector.preferred_mode.width);
        const disp_h: u64 = @intCast(connector.preferred_mode.height);

        const src_w: u64 = @intCast(image.width);
        const src_h: u64 = @intCast(image.height);
        const rot_w: u64 = @intCast(image.height);
        const rot_h: u64 = @intCast(image.width);
        const sf = @min(
            @as(f32, @floatFromInt(disp_w)) / @as(f32, @floatFromInt(rot_w)),
            @as(f32, @floatFromInt(disp_h)) / @as(f32, @floatFromInt(rot_h)),
        );

        const crtc_w: u64 = @intFromFloat(@round(@as(f32, @floatFromInt(rot_w)) * sf));
        const crtc_h: u64 = @intFromFloat(@round(@as(f32, @floatFromInt(rot_h)) * sf));
        try at.addProperty(plane.id, plane.props.fb_id, fb);
        try at.addProperty(plane.id, plane.props.crtc_id, crtc.id);
        try at.addProperty(plane.id, plane.props.src_x, 0);
        try at.addProperty(plane.id, plane.props.src_y, 0);
        try at.addProperty(plane.id, plane.props.src_w, src_w << 16);
        try at.addProperty(plane.id, plane.props.src_h, src_h << 16);
        try at.addProperty(plane.id, plane.props.crtc_x, (disp_w - crtc_w) / 2);
        try at.addProperty(plane.id, plane.props.crtc_y, (disp_h - crtc_h) / 2);
        try at.addProperty(plane.id, plane.props.crtc_w, crtc_w);
        try at.addProperty(plane.id, plane.props.crtc_h, crtc_h);
        try at.addProperty(plane.id, plane.props.rotation, 1 << 1);
        try at.commit();
    }

    while (true) {
        std.time.sleep(std.time.ns_per_s);
    }
}

fn createFramebuffer(drm: libDrm.DrmHandle, image: transform.Image) !u32 {
    var result: i32 = undefined;

    const dev = c.omap_device_new(drm.fd);
    const omap_bo = c.omap_bo_new_tiled(dev, image.width, image.height, c.OMAP_BO_TILED_32 | c.OMAP_BO_SCANOUT | c.OMAP_BO_WC) orelse return error.OmapBO;

    result = c.omap_bo_cpu_prep(omap_bo, c.OMAP_GEM_WRITE);
    if (result < 0) {
        return error.OmapCpuPrep;
    }

    const mapped_buf: [*]u8 = @ptrCast(c.omap_bo_map(omap_bo) orelse return error.OmapBOMap);
    const pitch = std.mem.alignForward(u32, image.width * 4, 4096);
    const buf_sz = c.omap_bo_size(omap_bo);
    std.log.debug("omap_bo: sz={}, pitch={}", .{ buf_sz, pitch });
    const mapped_slice = mapped_buf[0..buf_sz];

    const handle = c.omap_bo_handle(omap_bo);

    for (0..image.height) |row| {
        const bw = image.width * 4;
        @memcpy(mapped_slice[pitch * row .. pitch * row + bw], image.data[bw * row .. bw * row + bw]);
    }

    std.posix.munmap(@alignCast(mapped_slice));

    result = c.omap_bo_cpu_fini(omap_bo, c.OMAP_GEM_WRITE);
    if (result < 0) {
        return error.OmapCpuFini;
    }

    var framebuffer: u32 = undefined;
    var handles = [4]u32{ handle, 0, 0, 0 };
    var pitches = [4]u32{ pitch, 0, 0, 0 };
    var offsets = [4]u32{ 0, 0, 0, 0 };
    result = c.drmModeAddFB2(drm.fd, image.width, image.height, c.DRM_FORMAT_XRGB8888, &handles, &pitches, &offsets, &framebuffer, 0);
    if (result < 0) {
        return error.AddFB;
    }
    return framebuffer;
}

fn createFramebufferDumb(drm: libDrm.DrmHandle, image: transform.Image) !u32 {
    var result: i32 = undefined;
    var breq = c.drm_mode_create_dumb{
        .width = image.height,
        .height = image.width,
        .bpp = 32,
    };
    result = c.drmIoctl(drm.fd, c.DRM_IOCTL_MODE_CREATE_DUMB, &breq);
    if (result < 0) {
        return error.CreateDumbBuffer;
    }

    std.log.debug("Created dumbbuf: {}x{}, pitch={}, sz={}", .{ breq.width, breq.height, breq.pitch, breq.size });

    var mreq = c.drm_mode_map_dumb{
        .handle = breq.handle,
    };
    result = c.drmIoctl(drm.fd, c.DRM_IOCTL_MODE_MAP_DUMB, &mreq);
    if (result < 0) {
        return error.MapDumbBuffer;
    }

    const map = try std.posix.mmap(null, @intCast(breq.size), std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, drm.fd, mreq.offset);
    defer std.posix.munmap(map);

    const staging = try std.heap.c_allocator.alloc(u8, @intCast(breq.size));
    defer std.heap.c_allocator.free(staging);

    var dst_image = transform.Image{
        .width = breq.width,
        .height = breq.height,
        .pitch = breq.pitch / 4,
        .data = staging,
    };
    var timer = try std.time.Timer.start();
    transform.transformTo(&dst_image, &image, .rotation_270);
    std.log.info("Rotation took {}ms", .{@as(f32, @floatFromInt(timer.lap())) / std.time.ns_per_ms});

    @memcpy(map, staging);
    std.log.info("Copy took {}ms", .{@as(f32, @floatFromInt(timer.lap())) / std.time.ns_per_ms});

    var framebuffer: u32 = undefined;
    var handles = [4]u32{ breq.handle, 0, 0, 0 };
    var pitches = [4]u32{ breq.pitch, 0, 0, 0 };
    var offsets = [4]u32{ 0, 0, 0, 0 };
    result = c.drmModeAddFB2(drm.fd, breq.width, breq.height, c.DRM_FORMAT_XRGB8888, &handles, &pitches, &offsets, &framebuffer, 0);
    if (result < 0) {
        return error.AddFB;
    }
    return framebuffer;
}
