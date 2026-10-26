//! The simulation: societies, scarce food patches, pheromone fields and
//! entities driven by a fly sub-circuit plus an evolved social network.

const std = @import("std");
const fly = @import("flybrain.zig");
const gen = @import("genome.zig");
const pher = @import("pheromone.zig");

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn dist(a: Vec2, b: Vec2) f32 {
        return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
    }
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(r: Rect, p: Vec2) bool {
        return p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h;
    }
    pub fn center(r: Rect) Vec2 {
        return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
    }
    pub fn inset(r: Rect, m: f32) Rect {
        return .{ .x = r.x + m, .y = r.y + m, .w = r.w - 2 * m, .h = r.h - 2 * m };
    }
};

pub const FoodType = enum(u8) { meat, plant, mineral, universal };
pub const food_type_count = 4;

pub const Shape = enum { triangle, circle, square };

pub const Society = struct {
    name: [:0]const u8,
    shape: Shape,
    color: [3]u8,
    territory: Rect,
    food: FoodType,
    harshness: f32,
    environment: [:0]const u8,
};

pub const societies = [_]Society{
    .{ .name = "Triangles", .shape = .triangle, .color = .{ 255, 90, 80 }, .territory = .{ .x = -650, .y = -450, .w = 500, .h = 400 }, .food = .meat, .harshness = 0.6, .environment = "Volcanic Wasteland" },
    .{ .name = "Circles", .shape = .circle, .color = .{ 90, 140, 255 }, .territory = .{ .x = 150, .y = -450, .w = 500, .h = 400 }, .food = .plant, .harshness = 0.1, .environment = "Lush Gardens" },
    .{ .name = "Squares", .shape = .square, .color = .{ 90, 230, 120 }, .territory = .{ .x = -250, .y = 100, .w = 500, .h = 400 }, .food = .mineral, .harshness = 0.3, .environment = "Crystal Caverns" },
};
pub const society_count = societies.len;

pub const bounds = Rect{ .x = -1000, .y = -800, .w = 2000, .h = 1600 };

// Pheromone channel layout.
pub fn scentChannel(t: FoodType) usize {
    return @backingInt(t);
}
pub fn trailChannel(s: usize) usize {
    return food_type_count + s;
}
pub fn alarmChannel(s: usize) usize {
    return food_type_count + society_count + s;
}
pub const channel_count = food_type_count + 2 * society_count;

pub const Scarcity = enum {
    abundant,
    normal,
    scarce,
    famine,

    pub fn regrowth(s: Scarcity) f32 {
        return switch (s) {
            .abundant => 2.0,
            .normal => 1.0,
            .scarce => 0.5,
            .famine => 0.2,
        };
    }
};

pub const Resource = struct {
    pos: Vec2,
    food: FoodType,
    amount: f32,
    patch: ?u16,
};

/// A cluster of food that regrows until its budget runs out, then moves.
pub const Patch = struct {
    food: FoodType,
    area: Rect,
    center: Vec2,
    radius: f32,
    budget: f32,
    timer: f32,
    live: u16,
};

pub const Death = enum { starved, old_age, killed };

pub const Entity = struct {
    id: u32,
    society: u8,
    pos: Vec2,
    heading: f32,
    energy: f32 = 100,
    age: f32 = 0,
    lifespan: f32,
    generation: u32 = 1,
    parents: [2]u32 = .{ 0, 0 },
    children: u32 = 0,
    hybrid: bool = false,
    repro_cooldown: f32 = 0,
    since_meal: f32 = 30,
    food_eaten: f32 = 0,
    kills: u32 = 0,

    genome: gen.Genome,
    brain: fly.State,
    senses: fly.Senses = .{},
    motor: fly.Motor = .{},
    feeding: bool = false,
    turn_base: f32 = 0, // slow baseline of the steering output
    odour_adapt: f32 = 0, // receptor adaptation, food odour
    alarm_adapt: f32 = 0, // receptor adaptation, alarm odour
    odour: f32 = 0, // unadapted levels, fed to the social network
    alarm: f32 = 0,

    action: gen.SocialAction = .forage,
    action_timer: f32 = 0,
    escape_timer: f32 = 0,

    // Refreshed every brain tick.
    touching: ?u32 = null,
    enemy: ?u32 = null,
    enemy_dist: f32 = 0,
    enemies_near: u32 = 0,
    ally: ?u32 = null,
    ally_dist: f32 = 0,
    allies_near: u32 = 0,
    mate: ?u32 = null,

    dead: ?Death = null,

    pub fn mature(e: *const Entity) bool {
        return e.age > maturity_age;
    }
    pub fn readyToMate(e: *const Entity) bool {
        const threshold = 90 - 30 * e.genome.trait(.fertility);
        return e.dead == null and e.mature() and e.repro_cooldown <= 0 and e.energy > threshold;
    }
};

pub const maturity_age: f32 = 30;
pub const max_energy: f32 = 150;
pub const max_population = 600;
pub const brain_hz: f32 = 20;
pub const history_len = 400;
const sense_range: f32 = 160;
const touch_range: f32 = 9;
const adapt_tau: f32 = 1.0;
const adapt_floor: f32 = 0.02;

pub const SocietyStats = struct {
    births: u32 = 0,
    deaths: [3]u32 = .{ 0, 0, 0 },
};

pub const World = struct {
    gpa: std.mem.Allocator,
    prng: std.Random.DefaultPrng,
    circuit: *const fly.Circuit,
    entities: std.ArrayList(Entity) = .empty,
    resources: std.ArrayList(Resource) = .empty,
    patches: std.ArrayList(Patch) = .empty,
    field: pher.Field,
    time: f32 = 0,
    next_id: u32 = 1,
    max_generation: u32 = 1,
    scarcity: Scarcity = .normal,
    brain_accum: f32 = 0,
    stats: [society_count]SocietyStats = @splat(.{}),
    history: [history_len][society_count]u16 = undefined,
    history_count: usize = 0,
    history_timer: f32 = 0,
    threads: usize,
    /// Skip the social network and always forage (used by tests).
    forage_only: bool = false,

    pub fn init(gpa: std.mem.Allocator, circuit: *const fly.Circuit, seed: u64) !World {
        var channels: [channel_count]pher.Channel = undefined;
        for (0..food_type_count) |t| channels[t] = pher.channelFor(.scent);
        for (0..society_count) |s| {
            channels[trailChannel(s)] = pher.channelFor(.trail);
            channels[alarmChannel(s)] = pher.channelFor(.alarm);
        }
        var w = World{
            .gpa = gpa,
            .prng = .init(seed),
            .circuit = circuit,
            .field = try .init(gpa, bounds.x, bounds.y, bounds.w, bounds.h, 16, &channels),
            .threads = @min(std.Thread.getCpuCount() catch 4, 10),
        };
        try w.populate();
        return w;
    }

    pub fn reset(w: *World, seed: u64) !void {
        for (w.entities.items) |e| free(w.gpa, e);
        w.entities.clearRetainingCapacity();
        w.resources.clearRetainingCapacity();
        w.patches.clearRetainingCapacity();
        w.field.clear();
        w.prng = .init(seed);
        w.time = 0;
        w.next_id = 1;
        w.max_generation = 1;
        w.brain_accum = 0;
        w.stats = @splat(.{});
        w.history_count = 0;
        w.history_timer = 0;
        try w.populate();
    }

    fn rng(w: *World) std.Random {
        return w.prng.random();
    }

    fn randomIn(w: *World, r: Rect) Vec2 {
        return .{ .x = r.x + w.rng().float(f32) * r.w, .y = r.y + w.rng().float(f32) * r.h };
    }

    fn populate(w: *World) !void {
        const wild = bounds.inset(150);
        for (societies) |s| {
            for (0..3) |_| try w.addPatch(s.food, s.territory.inset(30));
            try w.addPatch(.universal, s.territory.inset(30));
        }
        for (0..4) |_| try w.addPatch(.universal, wild);
        for ([_]FoodType{ .meat, .plant, .mineral }) |t| try w.addPatch(t, wild);
        for (w.patches.items, 0..) |*p, i| {
            while (p.live < patch_items) try w.spawnFood(p, @intCast(i));
        }

        for (societies, 0..) |s, si| {
            for (0..25) |_| {
                const g = try gen.Genome.random(w.gpa, w.rng(), w.circuit.types);
                const e = try w.addEntity(@intCast(si), w.randomIn(s.territory.inset(40)), g);
                e.age = w.rng().float(f32) * maturity_age * 1.5;
            }
        }
    }

    const patch_items = 8;
    const food_amount: f32 = 40;

    fn addPatch(w: *World, food: FoodType, area: Rect) !void {
        var p = Patch{ .food = food, .area = area, .center = undefined, .radius = 0, .budget = 0, .timer = 0, .live = 0 };
        w.relocate(&p);
        try w.patches.append(w.gpa, p);
    }

    fn relocate(w: *World, p: *Patch) void {
        p.center = w.randomIn(p.area);
        p.radius = 20 + w.rng().float(f32) * 30;
        p.budget = 500 + w.rng().float(f32) * 400;
        p.timer = 0;
    }

    fn spawnFood(w: *World, p: *Patch, index: u16) !void {
        const a = w.rng().float(f32) * std.math.tau;
        const d = @sqrt(w.rng().float(f32)) * p.radius;
        try w.resources.append(w.gpa, .{
            .pos = .{ .x = p.center.x + @cos(a) * d, .y = p.center.y + @sin(a) * d },
            .food = p.food,
            .amount = food_amount,
            .patch = index,
        });
        p.budget -= food_amount;
        p.live += 1;
    }

    fn addEntity(w: *World, society: u8, pos: Vec2, genome: gen.Genome) !*Entity {
        const brain = try fly.State.init(w.gpa, w.circuit);
        try w.entities.append(w.gpa, .{
            .id = w.next_id,
            .society = society,
            .pos = pos,
            .heading = w.rng().float(f32) * std.math.tau,
            .lifespan = 220 + w.rng().float(f32) * 120,
            .genome = genome,
            .brain = brain,
        });
        w.next_id += 1;
        return &w.entities.items[w.entities.items.len - 1];
    }

    fn free(gpa: std.mem.Allocator, e: Entity) void {
        e.genome.deinit(gpa);
        e.brain.deinit(gpa);
    }

    pub fn findById(w: *World, id: u32) ?*Entity {
        for (w.entities.items) |*e| if (e.id == id and e.dead == null) return e;
        return null;
    }

    pub fn canEat(e: *const Entity, food: FoodType) f32 {
        if (food == .universal or food == societies[e.society].food) return 1.0;
        const adapt = e.genome.trait(.adaptability);
        if (e.hybrid or adapt > 0.6) return 0.5;
        return 0;
    }

    pub fn population(w: *const World, society: usize) u32 {
        var n: u32 = 0;
        for (w.entities.items) |e| {
            if (e.dead == null and e.society == society) n += 1;
        }
        return n;
    }

    /// Advance the simulation by one fixed tick.
    pub fn step(w: *World, dt: f32) !void {
        w.time += dt;
        w.field.update(dt);
        try w.updateFood(dt);

        w.brain_accum += dt;
        if (w.brain_accum >= 1 / brain_hz) {
            w.brain_accum -= 1 / brain_hz;
            w.removeDead();
            w.removeEaten();
            w.think();
        }

        const n = w.entities.items.len;
        for (0..n) |i| {
            if (w.entities.items[i].dead == null) try w.act(i, dt);
        }

        w.history_timer += dt;
        if (w.history_timer >= 2) {
            w.history_timer = 0;
            var row: [society_count]u16 = undefined;
            for (&row, 0..) |*r, s| r.* = @intCast(w.population(s));
            if (w.history_count < history_len) {
                w.history[w.history_count] = row;
                w.history_count += 1;
            } else {
                std.mem.copyForwards([society_count]u16, w.history[0 .. history_len - 1], w.history[1..]);
                w.history[history_len - 1] = row;
            }
        }
    }

    fn updateFood(w: *World, dt: f32) !void {
        const rate = w.scarcity.regrowth();
        for (w.patches.items, 0..) |*p, i| {
            if (p.budget <= 0) {
                if (p.live == 0) w.relocate(p);
                continue;
            }
            p.timer += dt * rate;
            if (p.timer >= 2.5) {
                p.timer = 0;
                if (p.live < patch_items) try w.spawnFood(p, @intCast(i));
            }
        }

        for (w.resources.items) |*r| {
            if (r.patch == null) r.amount -= 1.2 * dt; // corpses rot
            if (r.amount > 0) w.field.deposit(scentChannel(r.food), r.pos.x, r.pos.y, r.amount / food_amount * 3.0 * dt);
        }
    }

    /// Drop eaten food. Only done at brain ticks so cached indices stay valid.
    fn removeEaten(w: *World) void {
        var i: usize = 0;
        while (i < w.resources.items.len) {
            const r = w.resources.items[i];
            if (r.amount <= 0) {
                if (r.patch) |pi| w.patches.items[pi].live -= 1;
                _ = w.resources.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn removeDead(w: *World) void {
        var i: usize = 0;
        while (i < w.entities.items.len) {
            const e = w.entities.items[i];
            if (e.dead) |_| {
                free(w.gpa, e);
                _ = w.entities.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    /// Sense, scan neighbours and run the fly circuit for every entity, in parallel.
    fn think(w: *World) void {
        const n = w.entities.items.len;
        const threads = if (n < 48) 1 else w.threads;
        if (threads == 1) return thinkRange(w, 0, n);

        var handles: [16]?std.Thread = @splat(null);
        const chunk = (n + threads - 1) / threads;
        for (0..threads) |t| {
            const start = t * chunk;
            const end = @min(n, start + chunk);
            if (start >= end) break;
            handles[t] = std.Thread.spawn(.{}, thinkRange, .{ w, start, end }) catch blk: {
                thinkRange(w, start, end);
                break :blk null;
            };
        }
        for (handles) |h| if (h) |t| t.join();
    }

    fn thinkRange(w: *World, start: usize, end: usize) void {
        for (w.entities.items[start..end]) |*e| w.thinkOne(e);
    }

    fn thinkOne(w: *const World, e: *Entity) void {
        const s = e.society;
        const smell = e.genome.motorGene(.smell);

        // Two antennae, either side of the heading.
        const ant = [2]Vec2{
            .{ .x = e.pos.x + 12 * @cos(e.heading - 0.5), .y = e.pos.y + 12 * @sin(e.heading - 0.5) },
            .{ .x = e.pos.x + 12 * @cos(e.heading + 0.5), .y = e.pos.y + 12 * @sin(e.heading + 0.5) },
        };
        var odour: [2]f32 = .{ 0, 0 };
        var alarm: [2]f32 = .{ 0, 0 };
        for (ant, 0..) |a, side| {
            odour[side] = w.field.sample(trailChannel(s), a.x, a.y);
            for (0..food_type_count) |t| {
                const edible = canEat(e, @fromBackingInt(@intCast(t)));
                if (edible > 0) odour[side] += edible * w.field.sample(scentChannel(@fromBackingInt(@intCast(t))), a.x, a.y);
            }
            alarm[side] = w.field.sample(alarmChannel(s), a.x, a.y);
        }
        e.odour = 1 - @exp(-(odour[0] + odour[1]));
        e.alarm = 1 - @exp(-(alarm[0] + alarm[1]));

        // Receptor adaptation: drive is concentration relative to a slowly
        // adapting mean. The circuit only passes left/right contrast for
        // drive around 0.05-0.15; above that its projection neurons saturate.
        const k = @min(1, 1 / (brain_hz * adapt_tau));
        e.odour_adapt += (0.5 * (odour[0] + odour[1]) - e.odour_adapt) * k;
        e.alarm_adapt += (0.5 * (alarm[0] + alarm[1]) - e.alarm_adapt) * k;
        var attr: [2]f32 = undefined;
        for (&attr, odour) |*o, c| o.* = @min(1, 0.08 * smell * c / (e.odour_adapt + adapt_floor));
        for (&alarm) |*o| o.* = @min(1, 0.3 * smell * o.* / (e.alarm_adapt + adapt_floor));

        // Taste: whatever food is under the entity.
        e.touching = null;
        var best: f32 = touch_range;
        for (w.resources.items, 0..) |r, ri| {
            if (r.amount <= 0) continue;
            const d = r.pos.dist(e.pos);
            if (d < best) {
                best = d;
                e.touching = @intCast(ri);
            }
        }
        var sugar: f32 = 0;
        var bitter: f32 = 0;
        if (e.touching) |ri| {
            const edible = canEat(e, w.resources.items[ri].food);
            sugar = edible;
            bitter = 1 - edible;
        }

        e.senses = .{ .attr_L = attr[0], .attr_R = attr[1], .alarm_L = alarm[0], .alarm_R = alarm[1], .sugar = sugar, .bitter = bitter };
        e.motor = fly.step(w.circuit, e.genome.fly_gain, e.brain, e.senses);

        // Neighbours.
        e.enemy = null;
        e.ally = null;
        e.mate = null;
        e.enemies_near = 0;
        e.allies_near = 0;
        e.enemy_dist = sense_range;
        e.ally_dist = sense_range;
        var mate_dist: f32 = sense_range;
        const ready = e.readyToMate();
        for (w.entities.items, 0..) |*o, oi| {
            if (o.id == e.id or o.dead != null) continue;
            const d = o.pos.dist(e.pos);
            if (d >= sense_range) continue;
            if (o.society != e.society) {
                e.enemies_near += 1;
                if (d < e.enemy_dist) {
                    e.enemy_dist = d;
                    e.enemy = @intCast(oi);
                }
            } else {
                e.allies_near += 1;
                if (d < e.ally_dist) {
                    e.ally_dist = d;
                    e.ally = @intCast(oi);
                }
            }
            if (ready and o.readyToMate() and d < mate_dist) {
                mate_dist = d;
                e.mate = @intCast(oi);
            }
        }
    }

    fn act(w: *World, i: usize, dt: f32) !void {
        const e = &w.entities.items[i];
        const g = &e.genome;
        const soc = societies[e.society];

        e.age += dt;
        e.since_meal += dt;
        e.repro_cooldown -= dt;
        e.escape_timer -= dt;

        // Social decision.
        e.action_timer -= dt;
        if (e.action_timer <= 0 and !w.forage_only) {
            e.action_timer = 0.5;
            e.action = g.decide(.{
                e.energy / max_energy,
                @min(e.since_meal / 30, 1),
                e.age / e.lifespan,
                if (e.enemy != null) 1 - e.enemy_dist / sense_range else 0,
                @as(f32, @floatFromInt(@min(e.enemies_near, 10))) / 5,
                if (e.ally != null) 1 - e.ally_dist / sense_range else 0,
                @as(f32, @floatFromInt(@min(e.allies_near, 10))) / 5,
                e.alarm,
                e.odour,
                if (e.mature()) 1 else 0,
                if (e.readyToMate()) 1 else 0,
                if (e.hybrid) 1 else 0,
            });
        }

        // Steering comes from the fly circuit unless a social goal overrides it.
        // A slow baseline is subtracted to cancel the connectome's built-in
        // left/right bias. The left antenna sits at heading - 0.5, so more
        // left-side DNa activity has to lower the heading.
        const m = e.motor;
        const turn_diff = m.turn_R - m.turn_L;
        e.turn_base += (turn_diff - e.turn_base) * @min(1, dt / 1.5);
        var turn = std.math.clamp(g.motorGene(.turn) * (turn_diff - e.turn_base), -6, 6) + g.motorGene(.wander) * w.rng().floatNorm(f32);
        const target: ?Vec2 = switch (e.action) {
            .forage => null,
            .fight => if (e.enemy) |o| w.entities.items[o].pos else null,
            .mate => if (e.mate) |o| w.entities.items[o].pos else null,
            .socialize => if (e.ally) |o| (if (e.ally_dist > 30 + 60 * g.trait(.sociability)) w.entities.items[o].pos else null) else null,
            .flee => if (e.enemy) |o| away(e.pos, w.entities.items[o].pos) else null,
        };
        if (target) |t| turn = steerTo(e.heading, e.pos, t, 5);

        // Stay near home; low territoriality roams further.
        const home = soc.territory.inset(-(60 + 400 * (1 - g.trait(.territoriality))));
        if (!home.contains(e.pos)) turn = steerTo(e.heading, e.pos, soc.territory.center(), 3);

        e.heading += turn * dt;

        // Speed: DNp09 drives walking, MDN backs up, the giant fibre bolts, MN9 stops to feed.
        const base = 30 + 40 * g.trait(.speed);
        var speed = base * (0.5 + g.motorGene(.forward) * m.fwd);
        if (m.back > 0.3) speed = -0.4 * base;
        if (m.escape > 0.5 and e.escape_timer <= -1) e.escape_timer = 0.4;
        if (e.escape_timer > 0) speed = base * 2.5;
        if (e.action == .flee and e.enemy != null) speed = base * 1.2;

        e.feeding = false;
        if (e.touching) |ri| {
            if (m.feed > g.motorGene(.feed_threshold) and w.resources.items[ri].pos.dist(e.pos) < touch_range + 4) {
                const r = &w.resources.items[ri];
                const value = canEat(e, r.food);
                if (r.amount > 0 and value > 0) {
                    e.feeding = true;
                    speed *= 0.1;
                    const bite = @min(r.amount, 30 * m.feed * dt);
                    r.amount -= bite;
                    e.energy = @min(max_energy, e.energy + bite * value);
                    e.food_eaten += bite * value;
                    e.since_meal = 0;
                }
            }
        }
        e.pos.x += @cos(e.heading) * speed * dt;
        e.pos.y += @sin(e.heading) * speed * dt;
        const edge = bounds.inset(5);
        if (!edge.contains(e.pos)) {
            e.pos.x = std.math.clamp(e.pos.x, edge.x, edge.x + edge.w);
            e.pos.y = std.math.clamp(e.pos.y, edge.y, edge.y + edge.h);
            e.heading += std.math.pi;
        }

        // Lay a food trail for a while after eating.
        if (e.since_meal < 12) {
            w.field.deposit(trailChannel(e.society), e.pos.x, e.pos.y, g.trait(.trail_output) * 2.0 * @exp(-e.since_meal / 5) * dt);
        }

        // Metabolism, harsher in hard environments.
        const harsh = if (soc.territory.contains(e.pos)) soc.harshness else 0.3;
        const drain = (0.5 + 0.6 * g.trait(.speed) - 0.4 * g.trait(.efficiency) + 0.01 * @abs(speed)) * (1 + 0.5 * harsh);
        e.energy -= drain * dt;

        // Combat.
        if (e.action == .fight) {
            if (e.enemy) |oi| {
                const o = &w.entities.items[oi];
                if (o.dead == null and o.pos.dist(e.pos) < 14) {
                    const dmg = (8 + 22 * g.trait(.aggression)) * dt;
                    o.energy -= dmg;
                    e.energy -= 3 * dt;
                    w.field.deposit(alarmChannel(o.society), o.pos.x, o.pos.y, dmg * 0.6);
                    if (o.energy <= 0 and o.dead == null) {
                        e.kills += 1;
                        try w.kill(oi, .killed);
                    }
                }
            }
        }

        // Any two ready adults that meet can breed; the mate action just makes them seek each other.
        if (e.mate) |oi| {
            const o = &w.entities.items[oi];
            if (o.pos.dist(e.pos) < 20 and e.readyToMate() and o.readyToMate() and w.entities.items.len < max_population) {
                try w.reproduce(i, oi);
            }
        }

        const me = &w.entities.items[i];
        if (me.dead == null) {
            if (me.energy <= 0) try w.kill(i, .starved) else if (me.age > me.lifespan) try w.kill(i, .old_age);
        }
    }

    fn kill(w: *World, i: usize, cause: Death) !void {
        const e = &w.entities.items[i];
        e.dead = cause;
        w.stats[e.society].deaths[@backingInt(cause)] += 1;
        w.field.deposit(alarmChannel(e.society), e.pos.x, e.pos.y, 8);
        if (cause != .old_age or w.rng().boolean()) {
            try w.resources.append(w.gpa, .{ .pos = e.pos, .food = .meat, .amount = 30, .patch = null });
        }
    }

    fn reproduce(w: *World, ai: usize, bi: usize) !void {
        const genome = blk: {
            const a = &w.entities.items[ai];
            const b = &w.entities.items[bi];
            break :blk try gen.Genome.child(w.gpa, w.rng(), &a.genome, &b.genome, 0.15);
        };
        const a = w.entities.items[ai];
        const b = w.entities.items[bi];
        const society = if (a.society == b.society or w.rng().boolean()) a.society else b.society;
        const pos = Vec2{
            .x = (a.pos.x + b.pos.x) / 2 + (w.rng().float(f32) - 0.5) * 20,
            .y = (a.pos.y + b.pos.y) / 2 + (w.rng().float(f32) - 0.5) * 20,
        };
        // addEntity may reallocate the list, so parents were copied above.
        const child = try w.addEntity(society, pos, genome);
        child.generation = @max(a.generation, b.generation) + 1;
        child.parents = .{ a.id, b.id };
        child.hybrid = a.society != b.society or a.hybrid or b.hybrid;
        child.energy = 50;
        child.since_meal = 0;
        w.max_generation = @max(w.max_generation, child.generation);
        w.stats[society].births += 1;

        for ([_]usize{ ai, bi }) |pi| {
            const p = &w.entities.items[pi];
            p.energy -= 25;
            p.repro_cooldown = 10;
            p.children += 1;
        }
    }
};

fn away(from: Vec2, threat: Vec2) Vec2 {
    return .{ .x = from.x * 2 - threat.x, .y = from.y * 2 - threat.y };
}

/// Angular velocity that turns `heading` toward `target`.
fn steerTo(heading: f32, pos: Vec2, target: Vec2, rate: f32) f32 {
    const want = std.math.atan2(target.y - pos.y, target.x - pos.x);
    var diff = want - heading;
    diff = @mod(diff + std.math.pi, std.math.tau) - std.math.pi;
    return std.math.clamp(diff * rate, -rate, rate);
}
