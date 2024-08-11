const std = @import("std");

const c = @cImport({
    @cInclude("libevdev.h");
});

pub const KeyCodes = enum {
    touch,
};

pub const AbsAxes = enum {
    x,
    y,
    z,
};

pub const Device = struct {
    inner: *c.libevdev,

    pub fn openPath(path: []const u8) !@This() {
        const fd = try std.posix.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);

        var dev: *c.libevdev = undefined;
        const status = c.libevdev_new_from_fd(fd, &dev);
        if (status < 0) {
            return error.LibEvdevError;
        }

        return .{ .inner = dev };
    }

    pub fn deinit(self: @This()) void {
        c.libevdev_free(self.inner);
    }
};

pub const DeviceIterator = struct {
    inner: std.fs.Dir.Iterator,

    pub fn next(self: @This()) !?[]const u8 {
        while (true) {
            const entry = try self.inner.next() orelse return null;
            if (entry.kind != .character_device) {
                continue;
            }
            const base = std.fs.path.basename(entry.path);
            if (!std.mem.startsWith(u8, base, "event")) {
                continue;
            }

            return entry.path;
        }
    }
};

pub fn enumerateDevices() DeviceIterator {
    const dir = try std.fs.openDirAbsolute("/dev/input", .{ .iterate = true });
    defer dir.close();

    const iter = dir.iterateAssumeFirstIteration();
    return .{ .inner = iter };
}
