// SPDX-License-Identifier: 0BSD

const std = @import("std");
const log = std.log.scoped(.drm);

const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

pub const PropertyBlob = struct {
    id: u32,
    fd: i32,

    pub fn deinit(self: @This()) void {
        _ = c.drmModeDestroyPropertyBlob(self.fd, self.id);
    }
};

pub const DisplayMode = struct {
    width: u16,
    height: u16,
    blob: PropertyBlob,

    pub fn deinit(self: @This()) void {
        self.blob.deinit();
    }
};

pub const ConnectorInfo = struct {
    id: u32,
    encoder: u32,
    preferred_mode: DisplayMode,

    pub fn deinit(self: @This()) void {
        self.preferred_mode.deinit();
    }
};

pub const CrtcInfo = struct {
    id: u32,
    idx: u5,
    prop_rotation: u32,
};

pub const PlaneInfo = struct {
    id: u32,
    props: PlaneProperties,
};

pub const PlaneProperties = struct {
    fb_id: u32,
    crtc_id: u32,
    src_x: u32,
    src_y: u32,
    src_w: u32,
    src_h: u32,
    crtc_x: u32,
    crtc_y: u32,
    crtc_w: u32,
    crtc_h: u32,
    rotation: u32,
};

pub const DrmHandle = struct {
    fd: i32,

    pub fn open(path: []const u8) !@This() {
        var result: i32 = undefined;
        const fd = try std.posix.open(path, .{ .ACCMODE = .RDWR }, 0);
        errdefer std.posix.close(fd);

        result = c.drmSetClientCap(fd, c.DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
        if (result < 0) {
            return error.SetClientCap;
        }
        result = c.drmSetClientCap(fd, c.DRM_CLIENT_CAP_ATOMIC, 1);
        if (result < 0) {
            return error.SetClientCap;
        }

        return .{ .fd = fd };
    }

    pub fn close(self: @This()) void {
        std.posix.close(self.fd);
    }

    pub fn findConnector(self: @This()) !ConnectorInfo {
        const rsrc = c.drmModeGetResources(self.fd) orelse return error.GetResources;
        defer c.drmModeFreeResources(rsrc);

        for (0..@intCast(rsrc.*.count_connectors)) |i| {
            const conn = c.drmModeGetConnector(self.fd, rsrc.*.connectors[i]);
            defer c.drmModeFreeConnector(conn);

            if (conn.*.connection != c.DRM_MODE_CONNECTED) {
                continue;
            }
            if (conn.*.count_modes == 0) {
                continue;
            }
            if (conn.*.encoder_id == 0) {
                continue;
            }

            const mode = conn.*.modes[0];
            var mode_blob: u32 = undefined;
            const result = c.drmModeCreatePropertyBlob(self.fd, &mode, @sizeOf(c.drmModeRes), &mode_blob);
            if (result != 0) {
                return error.CreatePropertyBlob;
            }

            return .{
                .id = conn.*.connector_id,
                .encoder = conn.*.encoder_id,
                .preferred_mode = .{
                    .width = mode.hdisplay,
                    .height = mode.vdisplay,
                    .blob = .{
                        .id = mode_blob,
                        .fd = self.fd,
                    },
                },
            };
        }

        return error.NoConnectorsAvailable;
    }

    pub fn findCrtc(self: @This(), connector: ConnectorInfo) !CrtcInfo {
        const encoder = c.drmModeGetEncoder(self.fd, connector.encoder);
        defer c.drmModeFreeEncoder(encoder);

        const idx = try blk: {
            const rsrc = c.drmModeGetResources(self.fd) orelse return error.GetResources;
            defer c.drmModeFreeResources(rsrc);
            for (0..@intCast(rsrc.*.count_crtcs)) |i| {
                if (rsrc.*.crtcs[i] == encoder.*.crtc_id) {
                    break :blk @as(u5, @intCast(i));
                }
            }
            break :blk error.CrtcNotFound;
        };
        const props = c.drmModeObjectGetProperties(self.fd, encoder.*.crtc_id, c.DRM_MODE_OBJECT_CRTC);
        defer c.drmModeFreeObjectProperties(props);

        return .{
            .id = encoder.*.crtc_id,
            .idx = idx,
            .prop_rotation = try getPropertyID(self.fd, props, "rotation"),
        };
    }

    pub fn findPrimaryPlane(self: @This(), crtc: CrtcInfo) !PlaneInfo {
        const rsrc = c.drmModeGetPlaneResources(self.fd) orelse return error.GetPlaneResources;
        defer c.drmModeFreePlaneResources(rsrc);

        for (0..@intCast(rsrc.*.count_planes)) |i| {
            const plane = c.drmModeGetPlane(self.fd, rsrc.*.planes[i]) orelse return error.GetPlane;
            defer c.drmModeFreePlane(plane);

            if (plane.*.possible_crtcs & (@as(u32, 1) << crtc.idx) == 0) continue;

            const props = c.drmModeObjectGetProperties(self.fd, plane.*.plane_id, c.DRM_MODE_OBJECT_PLANE);
            defer c.drmModeFreeObjectProperties(props);

            const ty = try getPropertyValue(self.fd, props, "type");
            if (ty == c.DRM_PLANE_TYPE_PRIMARY) {
                return .{
                    .id = plane.*.plane_id,
                    .props = .{
                        .fb_id = try getPropertyID(self.fd, props, "FB_ID"),
                        .crtc_id = try getPropertyID(self.fd, props, "CRTC_ID"),
                        .src_x = try getPropertyID(self.fd, props, "SRC_X"),
                        .src_y = try getPropertyID(self.fd, props, "SRC_Y"),
                        .src_w = try getPropertyID(self.fd, props, "SRC_W"),
                        .src_h = try getPropertyID(self.fd, props, "SRC_H"),
                        .crtc_x = try getPropertyID(self.fd, props, "CRTC_X"),
                        .crtc_y = try getPropertyID(self.fd, props, "CRTC_Y"),
                        .crtc_w = try getPropertyID(self.fd, props, "CRTC_W"),
                        .crtc_h = try getPropertyID(self.fd, props, "CRTC_H"),
                        .rotation = try getPropertyID(self.fd, props, "rotation"),
                    },
                };
            }
        }

        return error.PrimaryPlaneNotFound;
    }

    pub fn newAtomic(self: @This()) !Atomic {
        const req = c.drmModeAtomicAlloc() orelse return error.DrmError;
        return .{ .fd = self.fd, .ptr = req };
    }
};

pub const Atomic = struct {
    fd: i32,
    ptr: *c.drmModeAtomicReq,

    pub fn deinit(self: @This()) void {
        c.drmModeAtomicFree(self.ptr);
    }

    pub fn commit(self: @This()) !void {
        const result = c.drmModeAtomicCommit(self.fd, self.ptr, c.DRM_MODE_ATOMIC_ALLOW_MODESET, null);
        if (result < 0) {
            std.log.err("drmModeAtomicCommit: {}", .{result});
            return error.DrmError;
        }
    }

    pub fn addProperty(self: @This(), object: u32, prop: u32, value: u64) !void {
        log.info("addProperty: {}={}", .{ prop, value });
        const result = c.drmModeAtomicAddProperty(self.ptr, object, prop, value);
        if (result < 0) {
            std.log.err("drmModeAtomicAddProperty: {}", .{result});
            return error.DrmError;
        }
    }
};

fn getPropertyValue(fd: i32, props: *const c.drmModeObjectProperties, name: []const u8) !u64 {
    for (0..@intCast(props.*.count_props)) |i| {
        const prop = c.drmModeGetProperty(fd, props.*.props[i]);
        defer c.drmModeFreeProperty(prop);

        const prop_name = std.mem.span(@as([*:0]const u8, @ptrCast(&prop.*.name)));
        if (std.mem.eql(u8, name, prop_name)) return props.*.prop_values[i];
    }

    return error.PropertyNotFound;
}

fn getPropertyID(fd: i32, props: *const c.drmModeObjectProperties, name: []const u8) !u32 {
    for (0..@intCast(props.*.count_props)) |i| {
        const prop = c.drmModeGetProperty(fd, props.*.props[i]);
        defer c.drmModeFreeProperty(prop);

        const prop_name = std.mem.span(@as([*:0]const u8, @ptrCast(&prop.*.name)));
        if (std.mem.eql(u8, name, prop_name)) return props.*.props[i];
    }

    return error.PropertyNotFound;
}
