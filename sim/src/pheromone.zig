//! Chemical fields on a grid: food scents, and per-society food trails and
//! alarm pheromone. Each channel diffuses and evaporates every tick.

const std = @import("std");

pub const Kind = enum { scent, trail, alarm };

pub const Channel = struct {
    kind: Kind,
    evaporation: f32, // fraction lost per second
    diffusion: f32, // spread rate per second (must stay < 1 / dt)
};

pub fn channelFor(kind: Kind) Channel {
    return switch (kind) {
        .scent => .{ .kind = kind, .evaporation = 0.35, .diffusion = 28.0 },
        .trail => .{ .kind = kind, .evaporation = 0.05, .diffusion = 0.4 },
        .alarm => .{ .kind = kind, .evaporation = 0.35, .diffusion = 15.0 },
    };
}

pub const Field = struct {
    cols: usize,
    rows: usize,
    cell: f32,
    origin_x: f32,
    origin_y: f32,
    channels: []Channel,
    data: [][]f32,
    scratch: []f32,

    pub fn init(gpa: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, cell: f32, channels: []const Channel) !Field {
        const cols: usize = @intFromFloat(@ceil(w / cell));
        const rows: usize = @intFromFloat(@ceil(h / cell));
        const data = try gpa.alloc([]f32, channels.len);
        for (data) |*d| {
            d.* = try gpa.alloc(f32, cols * rows);
            @memset(d.*, 0);
        }
        const scratch = try gpa.alloc(f32, cols * rows);
        return .{
            .cols = cols,
            .rows = rows,
            .cell = cell,
            .origin_x = x,
            .origin_y = y,
            .channels = try gpa.dupe(Channel, channels),
            .data = data,
            .scratch = scratch,
        };
    }

    pub fn clear(f: *Field) void {
        for (f.data) |d| @memset(d, 0);
    }

    pub fn deposit(f: *Field, ch: usize, x: f32, y: f32, amount: f32) void {
        const gx = (x - f.origin_x) / f.cell;
        const gy = (y - f.origin_y) / f.cell;
        if (gx < 0 or gy < 0) return;
        const cx: usize = @intFromFloat(gx);
        const cy: usize = @intFromFloat(gy);
        if (cx >= f.cols or cy >= f.rows) return;
        f.data[ch][cy * f.cols + cx] += amount;
    }

    /// Bilinear sample at a world position.
    pub fn sample(f: *const Field, ch: usize, x: f32, y: f32) f32 {
        const gx = std.math.clamp((x - f.origin_x) / f.cell - 0.5, 0, @as(f32, @floatFromInt(f.cols - 2)));
        const gy = std.math.clamp((y - f.origin_y) / f.cell - 0.5, 0, @as(f32, @floatFromInt(f.rows - 2)));
        const cx: usize = @intFromFloat(gx);
        const cy: usize = @intFromFloat(gy);
        const fx = gx - @as(f32, @floatFromInt(cx));
        const fy = gy - @as(f32, @floatFromInt(cy));
        const d = f.data[ch];
        const i = cy * f.cols + cx;
        const top = d[i] * (1 - fx) + d[i + 1] * fx;
        const bot = d[i + f.cols] * (1 - fx) + d[i + f.cols + 1] * fx;
        return top * (1 - fy) + bot * fy;
    }

    pub fn update(f: *Field, dt: f32) void {
        const cols = f.cols;
        const rows = f.rows;
        for (f.data, f.channels) |d, ch| {
            const keep = @exp(-ch.evaporation * dt);
            const k = @min(ch.diffusion * dt, 0.9);
            for (0..rows) |y| {
                for (0..cols) |x| {
                    const i = y * cols + x;
                    const v = d[i];
                    const l = if (x > 0) d[i - 1] else v;
                    const r = if (x + 1 < cols) d[i + 1] else v;
                    const u = if (y > 0) d[i - cols] else v;
                    const w = if (y + 1 < rows) d[i + cols] else v;
                    f.scratch[i] = (v + k * ((l + r + u + w) * 0.25 - v)) * keep;
                }
            }
            @memcpy(d, f.scratch);
        }
    }
};
