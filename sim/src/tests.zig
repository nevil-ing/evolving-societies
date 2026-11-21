const std = @import("std");
const fly = @import("flybrain.zig");
const gen = @import("genome.zig");
const sim = @import("world.zig");
const World = sim.World;

const blob = @embedFile("flybrain");
const slow = @import("build_options").slow;

fn settle(c: *const fly.Circuit, gains: []const f32, s: fly.State, senses: fly.Senses) fly.Motor {
    var m: fly.Motor = .{};
    for (0..60) |_| m = fly.step(c, gains, s, senses);
    return m;
}

test "circuit: sugar drives MN9, bitter does not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try fly.Circuit.parse(a, blob);
    const gains = try a.alloc(f32, c.types);
    @memset(gains, 1);

    const sweet = settle(&c, gains, try fly.State.init(a, &c), .{ .sugar = 1 });
    const bitter = settle(&c, gains, try fly.State.init(a, &c), .{ .bitter = 1 });
    const quiet = settle(&c, gains, try fly.State.init(a, &c), .{});
    try std.testing.expect(sweet.feed > 0.8);
    try std.testing.expect(bitter.feed < 0.1);
    try std.testing.expectEqual(@as(f32, 0), quiet.feed);
}

test "circuit: odour on one side biases the same-side DNa" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try fly.Circuit.parse(a, blob);
    const gains = try a.alloc(f32, c.types);
    @memset(gains, 1);

    const left = settle(&c, gains, try fly.State.init(a, &c), .{ .attr_L = 1 });
    const right = settle(&c, gains, try fly.State.init(a, &c), .{ .attr_R = 1 });
    try std.testing.expect(left.turn_L - left.turn_R > right.turn_L - right.turn_R);
}

test "world: populations survive the first two minutes" {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, 7919);
    for (0..60 * 120) |_| try w.step(1.0 / 60.0);
    var total: u32 = 0;
    for (0..sim.society_count) |s| total += w.population(s);
    try std.testing.expect(total > 0);
    try std.testing.expect(w.max_generation > 1);
}

/// One food patch with entities on a ring around it; returns how many reach it.
fn chemotaxis(steer: bool, seed: u64) !usize {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, seed);
    w.forage_only = true;
    // Remove every patch (not just empty it: an empty patch relocates and regrows).
    w.resources.clearRetainingCapacity();
    w.patches.clearRetainingCapacity();
    const home = sim.societies[1].territory.center();
    for (0..8) |k| {
        const a = @as(f32, @floatFromInt(k)) * 0.8;
        try w.resources.append(gpa, .{ .pos = .{ .x = home.x + 15 * @cos(a), .y = home.y + 15 * @sin(a) }, .food = .plant, .amount = 1e6, .patch = null });
    }
    w.field.clear();
    for (0..60 * 20) |_| {
        for (w.resources.items) |r| w.field.deposit(sim.scentChannel(r.food), r.pos.x, r.pos.y, 3.0 / 60.0);
        w.field.update(1.0 / 60.0);
    }

    var prng = std.Random.DefaultPrng.init(seed);
    for (w.entities.items) |*e| {
        const a = prng.random().float(f32) * std.math.tau;
        e.society = 1;
        e.pos = .{ .x = home.x + 150 * @cos(a), .y = home.y + 150 * @sin(a) };
        e.genome.traits[@backingInt(gen.Trait.territoriality)] = 1;
        e.energy = sim.max_energy;
        e.age = 0;
        if (!steer) e.genome.motor[@backingInt(gen.MotorGene.turn)] = 0;
    }
    const n = w.entities.items.len;
    const found = try gpa.alloc(bool, n);
    defer gpa.free(found);
    @memset(found, false);
    for (0..60 * 40) |_| {
        try w.step(1.0 / 60.0);
        for (w.entities.items[0..n], found) |e, *f| {
            if (e.pos.dist(home) < 25) f.* = true;
        }
    }
    var count: usize = 0;
    for (found) |f| count += @intFromBool(f);
    return count;
}

test "slow: fly steering reaches food at least twice as often as wandering" {
    if (!slow) return error.SkipZigTest;
    var with: usize = 0;
    var without: usize = 0;
    std.debug.print("\n", .{});
    for (1..11) |seed| {
        const a = try chemotaxis(true, seed);
        const b = try chemotaxis(false, seed);
        std.debug.print("seed {d:>2}: steering {d:>3}  no steering {d:>3}\n", .{ seed, a, b });
        try std.testing.expect(a > b);
        with += a;
        without += b;
    }
    std.debug.print("total reached food in 40s: fly steering {d}, no steering {d}\n", .{ with, without });
    try std.testing.expect(with >= 2 * without);
}

test "slow: populations across seeds" {
    if (!slow) return error.SkipZigTest;
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);
    std.debug.print("\n", .{});
    for (1..7) |seed| {
        var w = try World.init(gpa, &c, seed * 7919);
        var pops: [8][sim.society_count]u32 = undefined;
        for (&pops) |*row| {
            for (0..60 * 75) |_| try w.step(1.0 / 60.0);
            for (row, 0..) |*p, s| p.* = w.population(s);
        }
        std.debug.print("seed {d}: gen {d:>3}, population every 75s: {any}\n", .{ seed, w.max_generation, pops });
    }
}
