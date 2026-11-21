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

test "world: entities stay separated and react physically on contact" {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, 42);
    // Keep only two rivals placed overlapping head-on.
    while (w.entities.items.len > 2) {
        const last = w.entities.pop().?;
        last.genome.deinit(gpa);
        last.brain.deinit(gpa);
    }
    w.entities.items[0].society = 0;
    w.entities.items[1].society = 1;
    w.entities.items[0].age = 40;
    w.entities.items[1].age = 40;
    w.entities.items[0].pos = .{ .x = 0, .y = 0 };
    w.entities.items[1].pos = .{ .x = 2, .y = 0 };

    try w.step(1.0 / 60.0);
    const a = w.entities.items[0];
    const b = w.entities.items[1];
    const dist = a.pos.dist(b.pos);
    try std.testing.expect(dist >= a.radius() + b.radius() - 0.1);
    try std.testing.expect(w.contact_count > 0);
    try std.testing.expect(a.bump_cooldown > 0 and b.bump_cooldown > 0);
}

test "world: hungry adaptable entity eats foreign food instead of passing over it" {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, 99);
    w.forage_only = true;
    w.resources.clearRetainingCapacity();
    w.patches.clearRetainingCapacity();
    while (w.entities.items.len > 1) {
        const last = w.entities.pop().?;
        last.genome.deinit(gpa);
        last.brain.deinit(gpa);
    }
    const e = &w.entities.items[0];
    e.society = 1; // Circles (native food: plant)
    e.hybrid = true; // can eat meat at 50%
    e.age = 40;
    e.energy = 30;
    e.pos = .{ .x = 0, .y = 0 };
    e.heading = 0;
    e.genome.traits[@backingInt(gen.Trait.speed)] = 1.0; // fast entity
    e.genome.motor[@backingInt(gen.MotorGene.feed_threshold)] = 0.25;
    for (e.genome.fly_gain) |*g| g.* = 1.0;

    // Place an inedible food-like check? No, place foreign meat right ahead of the fast hybrid.
    try w.resources.append(gpa, .{ .pos = .{ .x = 6, .y = 0 }, .food = .meat, .amount = 40, .patch = null });
    for (0..60) |_| try w.step(1.0 / 60.0);
    try std.testing.expect(w.entities.items[0].food_eaten > 1.0);
    try std.testing.expect(w.entities.items[0].skill(.foraging) > 0);
}

test "world: skills pass down to offspring and civilization alerts fire" {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, 123);
    // Keep two skilled Circle adults right next to each other; Triangles & Squares empty -> extinct alert!
    while (w.entities.items.len > 2) {
        const last = w.entities.pop().?;
        last.genome.deinit(gpa);
        last.brain.deinit(gpa);
    }
    for (w.entities.items, 0..) |*e, idx| {
        e.society = 1;
        e.age = 50;
        e.energy = 140;
        e.repro_cooldown = 0;
        e.pos = .{ .x = @as(f32, @floatFromInt(idx)) * 18, .y = 0 };
        e.skills[@backingInt(sim.Skill.foraging)] = 0.8;
        e.skills[@backingInt(sim.Skill.care)] = 0.8;
    }

    for (0..90) |_| try w.step(1.0 / 60.0);

    // Offspring should have been born and inherited foraging & care skills from skilled parents.
    try std.testing.expect(w.entities.items.len >= 3);
    const child = w.entities.items[w.entities.items.len - 1];
    try std.testing.expect(child.generation >= 2);
    try std.testing.expect(child.skill(.foraging) > 0.25);
    try std.testing.expect(child.skill(.care) > 0.25);
    try std.testing.expect(w.gen_record_count >= 2);

    // Status watcher should have flagged extinct/endangered societies and emitted events.
    try std.testing.expectEqual(sim.SocietyStatus.extinct, w.stats[0].status);
    try std.testing.expectEqual(sim.SocietyStatus.endangered, w.stats[1].status);
    try std.testing.expect(w.event_count >= 2);
}

test "world: adventurous entities travel outside home territory and world phases cycle" {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, 777);
    for (0..60 * 70) |_| try w.step(1.0 / 60.0);

    var outside_home: usize = 0;
    for (w.entities.items) |e| {
        if (e.dead != null) continue;
        if (!w.territories[e.society].contains(e.pos)) outside_home += 1;
    }
    try std.testing.expect(outside_home >= 10);
    // Advance into the 5-minute cycle's storm phase (235..300s).
    w.time = 240;
    for (0..65) |_| try w.step(1.0 / 60.0);
    try std.testing.expectEqual(sim.WorldPhase.storm, w.phase);
}

test "world: tired well-fed entity rests to recover fatigue and territories shift with population" {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, 909);
    // Keep 6 tired, well-fed Circles shifted south-west of their initial territory.
    while (w.entities.items.len > 6) {
        const last = w.entities.pop().?;
        last.genome.deinit(gpa);
        last.brain.deinit(gpa);
    }
    const start_center = w.territories[1].center();
    for (w.entities.items, 0..) |*e, idx| {
        e.society = 1;
        e.age = 50;
        e.energy = 120;
        e.fatigue = 0.92;
        e.pos = .{ .x = -100 + @as(f32, @floatFromInt(idx)) * 22, .y = 300 };
    }
    for (0..60 * 3) |_| try w.step(1.0 / 60.0);

    // Fatigue should have dropped via resting, and Circles territory should have drifted toward (-45, 300).
    try std.testing.expect(w.entities.items[0].fatigue < 0.85);
    const end_center = w.territories[1].center();
    try std.testing.expect(end_center.x < start_center.x - 5);
    try std.testing.expect(end_center.y > start_center.y + 5);
}

test "cognitive brain: neurogenesis, synaptogenesis, and reward plasticity work" {
    var prng = std.Random.DefaultPrng.init(2026);
    const rng = prng.random();
    var brain = gen.CognitiveBrain.random(rng);
    const start_neurons = brain.totalNeurons();
    const start_synapses = brain.activeSynapses();

    try std.testing.expect(brain.addNeuron(rng));
    try std.testing.expectEqual(start_neurons + 1, brain.totalNeurons());
    try std.testing.expectEqual(start_synapses + 1, brain.activeSynapses());

    try std.testing.expect(brain.sproutFromExperience(rng));
    try std.testing.expectEqual(@as(u16, 1), brain.lifetime_rewires);

    // Run a decision then apply positive reward: weights on active paths should adapt.
    _ = brain.decide(.{ 0.8, 0.5, 0.2, 0, 0, 0.4, 0.2, 0, 0.7, 1, 1, 0 });
    var before: f32 = 0;
    for (brain.synapses[0..brain.synapse_count]) |s| if (s.active) {
        before += @abs(s.weight);
    };
    brain.learn(1.0);
    var after: f32 = 0;
    for (brain.synapses[0..brain.synapse_count]) |s| if (s.active) {
        after += @abs(s.weight);
    };
    try std.testing.expect(@abs(after - before) > 1e-4);
}

test "world: starving entity spots nearby food visually and eats instead of idling" {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, 314);
    w.resources.clearRetainingCapacity();
    w.patches.clearRetainingCapacity();
    w.field.clear();
    while (w.entities.items.len > 1) {
        const last = w.entities.pop().?;
        last.genome.deinit(gpa);
        last.brain.deinit(gpa);
    }
    const e = &w.entities.items[0];
    e.society = 2; // Squares (mineral)
    e.age = 40;
    e.energy = 28; // starving
    e.pos = .{ .x = 0, .y = 0 };
    e.heading = std.math.pi; // facing away from the food!
    e.genome.motor[@backingInt(gen.MotorGene.feed_threshold)] = 0.25;
    for (e.genome.fly_gain) |*g| g.* = 1.0;

    // Place food 65 units away with ZERO pre-diffused scent.
    try w.resources.append(gpa, .{ .pos = .{ .x = 65, .y = 0 }, .food = .mineral, .amount = 40, .patch = null });
    for (0..60 * 5) |_| try w.step(1.0 / 60.0);
    try std.testing.expect(w.entities.items[0].food_eaten > 1.0);
}

test "world: entities huddle during storms for shelter" {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, 555);
    w.phase = .storm;
    // Place 3 Circle allies near each other outside home territory during a storm.
    while (w.entities.items.len > 3) {
        const last = w.entities.pop().?;
        last.genome.deinit(gpa);
        last.brain.deinit(gpa);
    }
    for (w.entities.items, 0..) |*e, idx| {
        e.society = 1;
        e.age = 40;
        e.energy = 100;
        e.pos = .{ .x = @as(f32, @floatFromInt(idx)) * 22, .y = 0 };
    }
    for (0..20) |_| try w.step(1.0 / 60.0);
    try std.testing.expect(w.entities.items[1].huddled);
}

test "world: food call recruits distant hungry kin toward shared food" {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, 808);
    w.resources.clearRetainingCapacity();
    w.patches.clearRetainingCapacity();
    w.field.clear();
    while (w.entities.items.len > 2) {
        const last = w.entities.pop().?;
        last.genome.deinit(gpa);
        last.brain.deinit(gpa);
    }
    // Caller feeding at (0, 0); hungry kin 160 units away (beyond visual sight!).
    const caller = &w.entities.items[0];
    caller.society = 1;
    caller.age = 40;
    caller.energy = 80;
    caller.pos = .{ .x = 0, .y = 0 };
    caller.genome.traits[@backingInt(gen.Trait.sociability)] = 0.9;
    caller.genome.motor[@backingInt(gen.MotorGene.feed_threshold)] = 0.25;
    for (caller.genome.fly_gain) |*g| g.* = 1.0;

    const kin = &w.entities.items[1];
    kin.society = 1;
    kin.age = 40;
    kin.energy = 50;
    kin.pos = .{ .x = 160, .y = 0 };
    kin.heading = 0; // facing away from the food!

    try w.resources.append(gpa, .{ .pos = .{ .x = 2, .y = 0 }, .food = .plant, .amount = 40, .patch = null });
    for (0..60 * 3) |_| try w.step(1.0 / 60.0);

    try std.testing.expect(w.stats[1].signals_sent > 0);
    try std.testing.expect(w.stats[1].signals_acted > 0);
    // Recruited kin should have turned around and moved significantly closer to the shared food.
    try std.testing.expect(w.entities.items[1].pos.x < 120);
}

test "world: spawnClone preserves captured traits, skills, cognitive brain, and lineage" {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, 606);
    const orig = &w.entities.items[0];
    orig.generation = 7;
    orig.lineage = 42;
    orig.skills[@backingInt(sim.Skill.foraging)] = 0.77;
    orig.genome.traits[@backingInt(gen.Trait.efficiency)] = 0.91;

    const clone = try w.spawnClone(
        orig.society,
        .{ .x = 0, .y = 0 },
        orig.genome.traits,
        orig.genome.motor,
        orig.genome.cog,
        orig.genome.fly_gain,
        orig.skills,
        orig.generation,
        orig.lineage,
        true,
    );
    try std.testing.expectEqual(@as(u32, 7), clone.generation);
    try std.testing.expectEqual(@as(u32, 42), clone.lineage);
    try std.testing.expect(clone.hybrid);
    try std.testing.expectApproxEqAbs(@as(f32, 0.77), clone.skill(.foraging), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.91), clone.genome.trait(.efficiency), 1e-5);
}

test "world: clearAllFood halts regrowth, floodFood populates, setPhase jumps weather" {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, 404);
    try std.testing.expect(w.foodCount() > 50);

    w.clearAllFood();
    try std.testing.expectEqual(@as(u32, 0), w.foodCount());
    try std.testing.expectEqual(sim.Scarcity.none, w.scarcity);
    // Step 5 seconds: zero food should regrow when scarcity is .none.
    for (0..60 * 5) |_| try w.step(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 0), w.foodCount());

    try w.floodFood(120);
    try std.testing.expectEqual(@as(u32, 120), w.foodCount());

    w.setPhase(.storm);
    try std.testing.expectEqual(sim.WorldPhase.storm, w.phase);
    try std.testing.expect(sim.phaseRemaining(w.phaseClock()) > 60);

    const spawned = try w.spawnRandomBatch(0, 10);
    try std.testing.expectEqual(@as(usize, 10), spawned);
}

test "world: starvation cannibalism emerges when all food is removed" {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try fly.Circuit.parse(arena.allocator(), blob);

    var w = try World.init(gpa, &c, 911);
    w.clearAllFood();
    while (w.entities.items.len > 2) {
        const last = w.entities.pop().?;
        last.genome.deinit(gpa);
        last.brain.deinit(gpa);
    }
    const hunter = &w.entities.items[0];
    hunter.society = 0; // Triangles (meat-eater)
    hunter.age = 45;
    hunter.energy = 32;
    hunter.since_meal = 28;
    hunter.pos = .{ .x = 0, .y = 0 };
    hunter.heading = 0;
    hunter.genome.traits[@backingInt(gen.Trait.aggression)] = 0.92;
    hunter.genome.traits[@backingInt(gen.Trait.speed)] = 0.85;
    hunter.genome.motor[@backingInt(gen.MotorGene.feed_threshold)] = 0.25;
    for (hunter.genome.fly_gain) |*g| g.* = 1.0;

    const prey = &w.entities.items[1];
    prey.society = 0; // Same society (kin!)
    prey.age = 45;
    prey.energy = 10;
    prey.since_meal = 28;
    prey.pos = .{ .x = 26, .y = 0 };
    prey.genome.traits[@backingInt(gen.Trait.aggression)] = 0.1;

    for (0..60 * 6) |_| try w.step(1.0 / 60.0);

    try std.testing.expect(w.stats[0].cannibal_kills >= 1);
    var saw_event = false;
    for (w.events[0..w.event_count]) |ev| {
        if (ev.kind == .cannibalism) saw_event = true;
    }
    try std.testing.expect(saw_event);
    // Survivor should have eaten from the fallen kin's corpse.
    try std.testing.expect(w.entities.items.len == 1);
    try std.testing.expect(w.entities.items[0].food_eaten > 1.0);
}
