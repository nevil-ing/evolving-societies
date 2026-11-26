//! A smell -> steer -> feed sub-circuit of the adult fruit fly brain
//! (FlyWire connectome), run as a threshold-linear rate model.
//!
//! The wiring is shared by every entity and never changes. What evolves is
//! one gain per cell type, which scales how strongly that type's neurons
//! drive their targets (left/right copies of a type share a gain).

const std = @import("std");

/// Input and output neuron groups, in the order tools/extract_circuit.py writes them.
pub const Port = enum(u8) {
    orn_attr_L,
    orn_attr_R, // attractive food-odour receptor neurons
    orn_alarm_L,
    orn_alarm_R, // CO2 / geosmin receptor neurons
    sugar_L,
    sugar_R, // sugar gustatory receptor neurons
    bitter_L,
    bitter_R, // bitter gustatory receptor neurons
    turn_L,
    turn_R, // DNa01 / DNa02 steering descending neurons
    fwd_L,
    fwd_R, // DNp09: forward walking
    back_L,
    back_R, // MDN: backward walking
    escape_L,
    escape_R, // giant fibre
    feed_L,
    feed_R, // MN9 proboscis motor neuron
};
pub const port_count = @typeInfo(Port).@"enum".field_names.len;

pub const Circuit = struct {
    neurons: u32,
    types: u32,
    gain: f32,
    type_of: []u32,
    row_ptr: []u32, // CSR by postsynaptic neuron
    pre: []u32,
    weight: []f32, // signed synapse count
    // CSC (presynaptic-major) index built on parse for sparse zero-skipping in step().
    col_ptr: []u32,
    post: []u32,
    csc_weight: []f32,
    ports: [port_count][]u32,

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Circuit {
        var r = Reader{ .bytes = bytes };
        if (!std.mem.eql(u8, r.take(4), "FLYB")) return error.BadMagic;
        if (r.u32le() != 1) return error.BadVersion;
        const n = r.u32le();
        const e = r.u32le();
        const n_types = r.u32le();
        const n_ports = r.u32le();
        _ = r.u32le();
        if (n_ports != port_count) return error.PortMismatch;

        var c: Circuit = undefined;
        c.neurons = n;
        c.types = n_types;
        c.gain = @bitCast(r.u32le());
        c.type_of = try r.u32s(gpa, n);
        c.row_ptr = try r.u32s(gpa, n + 1);
        c.pre = try r.u32s(gpa, e);
        const w = try r.u32s(gpa, e);
        c.weight = @ptrCast(w);
        for (&c.ports, 0..) |*p, i| {
            const name = std.mem.sliceTo(r.take(16), 0);
            if (!std.mem.eql(u8, name, @tagName(@as(Port, @fromBackingInt(@intCast(i)))))) return error.PortMismatch;
            p.* = try r.u32s(gpa, r.u32le());
        }

        // Transpose CSR -> CSC (presynaptic-major) so step() skips inactive neurons (r <= 1e-4).
        c.col_ptr = try gpa.alloc(u32, n + 1);
        @memset(c.col_ptr, 0);
        for (c.pre) |j| c.col_ptr[j + 1] += 1;
        for (0..n) |j| c.col_ptr[j + 1] += c.col_ptr[j];
        c.post = try gpa.alloc(u32, e);
        c.csc_weight = try gpa.alloc(f32, e);
        const cursor = try gpa.dupe(u32, c.col_ptr[0..n]);
        defer gpa.free(cursor);
        for (0..n) |i| {
            for (c.row_ptr[i]..c.row_ptr[i + 1]) |k| {
                const j = c.pre[k];
                const dst = cursor[j];
                c.post[dst] = @intCast(i);
                c.csc_weight[dst] = c.weight[k];
                cursor[j] += 1;
            }
        }
        return c;
    }

    pub fn connections(c: Circuit) usize {
        return c.pre.len;
    }
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(r: *Reader, len: usize) []const u8 {
        defer r.pos += len;
        return r.bytes[r.pos..][0..len];
    }
    fn u32le(r: *Reader) u32 {
        return std.mem.readInt(u32, r.take(4)[0..4], .little);
    }
    fn u32s(r: *Reader, gpa: std.mem.Allocator, len: usize) ![]u32 {
        const out = try gpa.alloc(u32, len);
        for (out) |*v| v.* = r.u32le();
        return out;
    }
};

/// Sensor drive for one brain tick, each 0..1.
pub const Senses = struct {
    attr_L: f32 = 0,
    attr_R: f32 = 0,
    alarm_L: f32 = 0,
    alarm_R: f32 = 0,
    sugar: f32 = 0,
    bitter: f32 = 0,
};

/// Mean activity of the motor/descending output groups.
pub const Motor = struct {
    turn_L: f32 = 0,
    turn_R: f32 = 0,
    fwd: f32 = 0,
    back: f32 = 0,
    escape: f32 = 0,
    feed: f32 = 0,
};

/// Per-entity neural state backed by a single contiguous allocation (v, r, acc) for cache locality.
pub const State = struct {
    buf: []f32,
    v: []f32,
    r: []f32,
    acc: []f32,

    pub fn init(gpa: std.mem.Allocator, c: *const Circuit) !State {
        const n: usize = c.neurons;
        const buf = try gpa.alloc(f32, n * 3);
        @memset(buf, 0);
        return .{
            .buf = buf,
            .v = buf[0..n],
            .r = buf[n .. 2 * n],
            .acc = buf[2 * n .. 3 * n],
        };
    }

    pub fn deinit(s: State, gpa: std.mem.Allocator) void {
        gpa.free(s.buf);
    }
};

/// Euler step as a fraction of the membrane time constant.
pub const dt_over_tau: f32 = 0.5;

/// Advance the circuit one tick using CSC presynaptic-major zero-skipping.
/// `type_gain` has one entry per cell type.
pub fn step(c: *const Circuit, type_gain: []const f32, s: State, senses: Senses) Motor {
    // Drive sensory neurons.
    const drive = [_]struct { Port, f32 }{
        .{ .orn_attr_L, senses.attr_L },   .{ .orn_attr_R, senses.attr_R },
        .{ .orn_alarm_L, senses.alarm_L }, .{ .orn_alarm_R, senses.alarm_R },
        .{ .sugar_L, senses.sugar },       .{ .sugar_R, senses.sugar },
        .{ .bitter_L, senses.bitter },     .{ .bitter_R, senses.bitter },
    };

    // Integrate synaptic input from active presynaptic rates only (skips 80-90% of zero-rate edges).
    @memset(s.acc, 0);
    for (0..c.neurons) |j| {
        const rj = s.r[j];
        if (rj <= 1e-4) continue;
        const scaled = rj * type_gain[c.type_of[j]];
        for (c.col_ptr[j]..c.col_ptr[j + 1]) |k| {
            s.acc[c.post[k]] += c.csc_weight[k] * scaled;
        }
    }
    for (0..c.neurons) |i| {
        s.v[i] += dt_over_tau * (c.gain * s.acc[i] - s.v[i]);
    }
    for (drive) |d| {
        for (c.ports[@backingInt(d[0])]) |i| s.v[i] += dt_over_tau * d[1];
    }
    for (s.v, s.r) |v, *r| r.* = std.math.clamp(v, 0, 1);

    return .{
        .turn_L = mean(c, s, .turn_L),
        .turn_R = mean(c, s, .turn_R),
        .fwd = 0.5 * (mean(c, s, .fwd_L) + mean(c, s, .fwd_R)),
        .back = 0.5 * (mean(c, s, .back_L) + mean(c, s, .back_R)),
        .escape = 0.5 * (mean(c, s, .escape_L) + mean(c, s, .escape_R)),
        .feed = 0.5 * (mean(c, s, .feed_L) + mean(c, s, .feed_R)),
    };
}

fn mean(c: *const Circuit, s: State, p: Port) f32 {
    const ids = c.ports[@backingInt(p)];
    if (ids.len == 0) return 0;
    var sum: f32 = 0;
    for (ids) |i| sum += s.r[i];
    return sum / @as(f32, @floatFromInt(ids.len));
}
