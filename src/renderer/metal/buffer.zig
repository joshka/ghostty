const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");

const mtl = @import("api.zig");
const Metal = @import("../Metal.zig");

const log = std.log.scoped(.metal);

/// Options for initializing a buffer.
pub const Options = struct {
    /// MTLDevice
    device: objc.Object,
    resource_options: mtl.MTLResourceOptions,
};

/// Metal data storage for a certain set of equal types. This is usually
/// used for vertex buffers, etc. This helpful wrapper makes it easy to
/// prealloc, shrink, grow, sync, buffers with Metal.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The options this buffer was initialized with.
        opts: Options,

        /// The underlying MTLBuffer object.
        buffer: objc.Object,

        /// The allocated length of the buffer.
        /// Note that this is the number
        /// of `T`s not the size in bytes.
        len: usize,

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(opts: Options, len: usize) !Self {
            const buffer = opts.device.msgSend(
                objc.Object,
                objc.sel("newBufferWithLength:options:"),
                .{
                    @as(c_ulong, @intCast(len * @sizeOf(T))),
                    opts.resource_options,
                },
            );

            return .{ .buffer = buffer, .opts = opts, .len = len };
        }

        /// Init the buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) !Self {
            const buffer = opts.device.msgSend(
                objc.Object,
                objc.sel("newBufferWithBytes:length:options:"),
                .{
                    @as(*const anyopaque, @ptrCast(data.ptr)),
                    @as(c_ulong, @intCast(data.len * @sizeOf(T))),
                    opts.resource_options,
                },
            );

            return .{ .buffer = buffer, .opts = opts, .len = data.len };
        }

        pub fn deinit(self: *const Self) void {
            self.buffer.msgSend(void, objc.sel("release"), .{});
        }

        /// Sync new contents to the buffer. The data is expected to be the
        /// complete contents of the buffer. If the amount of data is larger
        /// than the buffer length, the buffer will be reallocated.
        ///
        /// If the amount of data is smaller than the buffer length, the
        /// remaining data in the buffer is left untouched.
        pub fn sync(self: *Self, data: []const T) !void {
            // If we need more bytes than our buffer has, we need to reallocate.
            const req_bytes = data.len * @sizeOf(T);
            const avail_bytes = self.buffer.getProperty(c_ulong, "length");
            if (req_bytes > avail_bytes) {
                // Deallocate previous buffer
                self.buffer.msgSend(void, objc.sel("release"), .{});

                // Allocate a new buffer with enough to hold double what we require.
                // `size` is already a byte count, so pass it directly.
                const size = req_bytes * 2;
                self.buffer = self.opts.device.msgSend(
                    objc.Object,
                    objc.sel("newBufferWithLength:options:"),
                    .{
                        @as(c_ulong, @intCast(size)),
                        self.opts.resource_options,
                    },
                );
            }

            // We can fit within the buffer so we can just replace bytes.
            const dst = dst: {
                const ptr = self.buffer.msgSend(?[*]u8, objc.sel("contents"), .{}) orelse {
                    log.warn("buffer contents ptr is null", .{});
                    return error.MetalFailed;
                };

                break :dst ptr[0..req_bytes];
            };

            const src = src: {
                const ptr = @as([*]const u8, @ptrCast(data.ptr));
                break :src ptr[0..req_bytes];
            };

            @memcpy(dst, src);

            // If we're using the managed resource storage mode, then
            // we need to signal Metal to synchronize the buffer data.
            //
            // Ref: https://developer.apple.com/documentation/metal/synchronizing-a-managed-resource-in-macos?language=objc
            if (self.opts.resource_options.storage_mode == .managed) {
                self.buffer.msgSend(
                    void,
                    "didModifyRange:",
                    .{macos.foundation.Range.init(0, req_bytes)},
                );
            }
        }

        /// Like Buffer.sync but takes data from an array of ArrayLists,
        /// rather than a single array. Returns the number of items synced.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| {
                total_len += list.items.len;
            }

            // If we need more bytes than our buffer has, we need to reallocate.
            const req_bytes = total_len * @sizeOf(T);
            const avail_bytes = self.buffer.getProperty(c_ulong, "length");
            if (req_bytes > avail_bytes) {
                // Deallocate previous buffer
                self.buffer.msgSend(void, objc.sel("release"), .{});

                // Allocate a new buffer with enough to hold double what we require.
                // `size` is already a byte count, so pass it directly.
                const size = req_bytes * 2;
                self.buffer = self.opts.device.msgSend(
                    objc.Object,
                    objc.sel("newBufferWithLength:options:"),
                    .{
                        @as(c_ulong, @intCast(size)),
                        self.opts.resource_options,
                    },
                );
            }

            // We can fit within the buffer so we can just replace bytes.
            const dst = dst: {
                const ptr = self.buffer.msgSend(?[*]u8, objc.sel("contents"), .{}) orelse {
                    log.warn("buffer contents ptr is null", .{});
                    return error.MetalFailed;
                };

                break :dst ptr[0..req_bytes];
            };

            var i: usize = 0;

            for (lists) |list| {
                const ptr = @as([*]const u8, @ptrCast(list.items.ptr));
                @memcpy(dst[i..][0 .. list.items.len * @sizeOf(T)], ptr);
                i += list.items.len * @sizeOf(T);
            }

            // If we're using the managed resource storage mode, then
            // we need to signal Metal to synchronize the buffer data.
            //
            // Ref: https://developer.apple.com/documentation/metal/synchronizing-a-managed-resource-in-macos?language=objc
            if (self.opts.resource_options.storage_mode == .managed) {
                self.buffer.msgSend(
                    void,
                    "didModifyRange:",
                    .{macos.foundation.Range.init(0, req_bytes)},
                );
            }

            return total_len;
        }
    };
}

test "REPRO ghostty-rs: sync grow allocates requested bytes, not @sizeOf(T)x more" {
    // Exercises the real Buffer(T).sync() grow path against a live MTLDevice and
    // reads the allocated byte length back. Skips on machines without a Metal
    // device (e.g. headless CI).
    const raw = mtl.MTLCreateSystemDefaultDevice() orelse return error.SkipZigTest;
    const device = objc.Object.fromId(raw);

    // A 32-byte element, the same @sizeOf as the real CellText wire struct.
    const Elem = extern struct { a: u64, b: u64, c: u64, d: u64 };
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Elem));

    // Start at 1 element, exactly like the renderer's per-frame cell buffers.
    var buf = try Buffer(Elem).init(.{
        .device = device,
        .resource_options = .{ .storage_mode = .shared },
    }, 1);
    defer buf.deinit();

    // Sync 4 elements (128 B > the 32 B initial buffer) to force a grow.
    var data: [4]Elem = undefined;
    try buf.sync(&data);

    const req_bytes: c_ulong = 4 * @sizeOf(Elem); // 128
    const want: c_ulong = req_bytes * 2; // 256 = "double what we require"
    const got = buf.buffer.getProperty(c_ulong, "length");

    std.debug.print(
        "\n[REPRO] synced {d} B; buffer.length = {d} (want {d}); over-allocated {d}x\n",
        .{ req_bytes, got, want, got / want },
    );

    // Fails today: got == 256 * @sizeOf(Elem) == 8192 (32x too large).
    try std.testing.expectEqual(want, got);
}
