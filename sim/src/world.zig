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
    owner: ?u8 = null, // tracks a society's dynamic living territory when set
    center: Vec2,
    radius: f32,
    budget: f32,
    timer: f32,
    live: u16,
};

pub const Death = enum { starved, old_age, killed };

pub const Skill = enum(u8) {
    foraging, // faster & higher-yield eating
    navigation, // lower travel cost & sharper scent tracking
    combat, // higher damage & better defense
    care, // stronger food sharing & skill transfer to youth/offspring
};
pub const skill_count = @typeInfo(Skill).@"enum".field_names.len;

pub const Role = enum(u8) {
    juvenile,
    novice,
    forager,
    scout,
    guard,
    caretaker,
    elder,
};

pub const SocietyStatus = enum(u8) { thriving, stable, struggling, endangered, extinct };

pub const WorldPhase = enum(u8) {
    calm,
    bloom,
    storm,

    pub fn regrowth(p: WorldPhase) f32 {
        return switch (p) {
            .calm => 1.0,
            .bloom => 1.6,
            .storm => 0.6,
        };
    }
    pub fn harshness(p: WorldPhase) f32 {
        return switch (p) {
            .calm => 1.0,
            .bloom => 0.9,
            .storm => 1.4,
        };
    }
};
pub const cycle_length: f32 = 300; // 5-minute cycle: 145s calm, 90s bloom, 65s storm

pub fn phaseRemaining(time: f32) f32 {
    const t = @mod(time, cycle_length);
    if (t < 145) return 145 - t;
    if (t < 235) return 235 - t;
    return cycle_length - t;
}

pub const EventKind = enum(u8) { endangered, critical, extinct, recovered, boom, milestone_gen, first_hybrid, hybrid_majority, territory_clash, world_bloom, world_storm };

pub const WorldEvent = struct {
    time: f32,
    society: u8,
    kind: EventKind,
    value: u32,
};
pub const max_events = 24;

pub const GenRecord = struct {
    gen: u32 = 0,
    births: u32 = 0,
    skill_sum: [skill_count]f32 = @splat(0),
    trait_eff_sum: f32 = 0,
    trait_aggr_sum: f32 = 0,
    trait_adapt_sum: f32 = 0,
    neuron_sum: f32 = 0,
    synapse_sum: f32 = 0,
};
pub const max_gen_records = 64;

pub const ContactKind = enum { kin_greet, share_food, rival_clash, startle, courtship };

pub const ContactEvent = struct {
    pos: Vec2,
    kind: ContactKind,
    society: u8,
    age: f32 = 0,
};
pub const contact_duration: f32 = 0.45;

pub const SignalKind = enum(u8) { food_found, danger_call, storm_rally, mate_call };

pub const Signal = struct {
    pos: Vec2,
    target: Vec2,
    kind: SignalKind,
    society: u8,
    radius: f32,
    age: f32 = 0,
};
pub const signal_duration: f32 = 0.9;

pub const Entity = struct {
    id: u32,
    society: u8,
    pos: Vec2,
    heading: f32,
    energy: f32 = 100,
    fatigue: f32 = 0,
    resting: bool = false,
    age: f32 = 0,
    lifespan: f32,
    generation: u32 = 1,
    lineage: u32 = 0,
    parents: [2]u32 = .{ 0, 0 },
    children: u32 = 0,
    hybrid: bool = false,
    repro_cooldown: f32 = 0,
    since_meal: f32 = 30,
    food_eaten: f32 = 0,
    kills: u32 = 0,
    skills: [skill_count]f32 = @splat(0),

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
    bump_vel: Vec2 = .{ .x = 0, .y = 0 },
    bump_cooldown: f32 = 0,
    explore_target: ?Vec2 = null,
    explore_timer: f32 = 0,
    distance_traveled: f32 = 0,
    call_cooldown: f32 = 0,
    heard_kind: ?SignalKind = null,
    heard_pos: Vec2 = .{ .x = 0, .y = 0 },
    heard_timer: f32 = 0,
    last_sent: ?SignalKind = null,

    // Refreshed every brain tick.
    touching: ?u32 = null,
    visible_food: ?Vec2 = null,
    huddled: bool = false,
    enemy: ?u32 = null,
    enemy_dist: f32 = 0,
    enemies_near: u32 = 0,
    ally: ?u32 = null,
    ally_dist: f32 = 0,
    allies_near: u32 = 0,
    mate: ?u32 = null,

    dead: ?Death = null,

    pub fn radius(e: *const Entity) f32 {
        return 8 * (0.55 + 0.45 * @min(1, e.age / maturity_age));
    }
    pub fn mature(e: *const Entity) bool {
        return e.age > maturity_age;
    }
    pub fn readyToMate(e: *const Entity) bool {
        const threshold = 90 - 30 * e.genome.trait(.fertility);
        return e.dead == null and e.mature() and e.repro_cooldown <= 0 and e.energy > threshold;
    }
    pub fn skill(e: *const Entity, s: Skill) f32 {
        return e.skills[@backingInt(s)];
    }
    pub fn addSkill(e: *Entity, s: Skill, delta: f32) void {
        if (delta <= 0) return;
        const idx = @backingInt(s);
        const cur = e.skills[idx];
        // Paced for 1-2h lifespans so role specialization stays distinct across generations.
        e.skills[idx] = std.math.clamp(cur + delta * 0.3 * (1 - cur * 0.65), 0, 1);
    }
    pub fn role(e: *const Entity) Role {
        if (!e.mature()) return .juvenile;
        var best_i: usize = 0;
        var best_v: f32 = e.skills[0];
        var total: f32 = 0;
        for (e.skills, 0..) |v, i| {
            total += v;
            if (v > best_v) {
                best_v = v;
                best_i = i;
            }
        }
        if (e.age > 300 and total >= 0.75) return .elder;
        if (best_v < 0.18) return .novice;
        return switch (@as(Skill, @fromBackingInt(@intCast(best_i)))) {
            .foraging => .forager,
            .navigation => .scout,
            .combat => .guard,
            .care => .caretaker,
        };
    }
};

pub const maturity_age: f32 = 30;
pub const max_energy: f32 = 150;
pub const max_population = 600;
pub const brain_hz: f32 = 20;
pub const history_len = 400;
const sense_range: f32 = 160;
const adapt_tau: f32 = 1.0;
const adapt_floor: f32 = 0.02;

pub const SocietyStats = struct {
    births: u32 = 0,
    deaths: [3]u32 = .{ 0, 0, 0 },
    max_gen: u32 = 1,
    peak_pop: u32 = 25,
    status: SocietyStatus = .stable,
    had_hybrid: bool = false,
    had_hybrid_majority: bool = false,
    boom_milestone: u32 = 50,
    gen_milestone: u32 = 3,
    extinct_time: ?f32 = null,
    signals_sent: u32 = 0,
    signals_acted: u32 = 0,
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
    status_timer: f32 = 0,
    clash_cooldown: f32 = 0,
    phase: WorldPhase = .calm,
    territories: [society_count]Rect = initTerritories(),
    events: [max_events]WorldEvent = undefined,
    event_count: usize = 0,
    gen_records: [max_gen_records]GenRecord = @splat(.{}),
    gen_record_count: usize = 0,
    contacts: [64]ContactEvent = undefined,
    contact_count: usize = 0,
    signals: [48]Signal = undefined,
    signal_count: usize = 0,
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
        w.status_timer = 0;
        w.clash_cooldown = 0;
        w.phase = .calm;
        w.territories = initTerritories();
        w.event_count = 0;
        w.gen_records = @splat(.{});
        w.gen_record_count = 0;
        w.contact_count = 0;
        w.signal_count = 0;
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
        for (societies, 0..) |s, si| {
            for (0..3) |_| try w.addPatch(s.food, s.territory.inset(30), @intCast(si));
            try w.addPatch(.universal, s.territory.inset(30), @intCast(si));
        }
        for (0..6) |_| try w.addPatch(.universal, wild, null);
        for ([_]FoodType{ .meat, .plant, .mineral }) |t| try w.addPatch(t, wild, null);
        for (w.patches.items, 0..) |*p, i| {
            while (p.live < patch_items) try w.spawnFood(p, @intCast(i));
        }

        for (societies, 0..) |s, si| {
            for (0..25) |_| {
                const g = try gen.Genome.random(w.gpa, w.rng(), w.circuit.types);
                const e = try w.addEntity(@intCast(si), w.randomIn(s.territory.inset(40)), g);
                e.age = w.rng().float(f32) * maturity_age * 1.5;
                e.lineage = e.id;
                w.recordGeneration(e);
            }
        }
    }

    const patch_items = 8;
    const food_amount: f32 = 40;

    fn addPatch(w: *World, food: FoodType, area: Rect, owner: ?u8) !void {
        var p = Patch{ .food = food, .area = area, .owner = owner, .center = undefined, .radius = 0, .budget = 0, .timer = 0, .live = 0 };
        w.relocate(&p);
        try w.patches.append(w.gpa, p);
    }

    fn relocate(w: *World, p: *Patch) void {
        if (p.owner) |si| {
            p.area = w.territories[si].inset(25);
        }
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
            .lifespan = 3600 + w.rng().float(f32) * 3600, // 1 to 2 simulated hours so individuals are easy to follow
            .genome = genome,
            .brain = brain,
        });
        w.next_id += 1;
        return &w.entities.items[w.entities.items.len - 1];
    }

    /// Release a cloned specimen (e.g. from the Specimen Lab) into the world.
    pub fn spawnClone(
        w: *World,
        society: u8,
        pos: Vec2,
        traits: [gen.trait_count]f32,
        motor: [gen.motor_count]f32,
        cog: gen.CognitiveBrain,
        fly_gain: []const f32,
        skills: [skill_count]f32,
        generation: u32,
        lineage: u32,
        hybrid: bool,
    ) !*Entity {
        const g = gen.Genome{
            .traits = traits,
            .motor = motor,
            .cog = cog,
            .fly_gain = try w.gpa.dupe(f32, fly_gain),
        };
        const e = try w.addEntity(society, pos, g);
        e.age = maturity_age + 5;
        e.energy = 110;
        e.skills = skills;
        e.generation = generation;
        e.lineage = if (lineage != 0) lineage else e.id;
        e.hybrid = hybrid;
        w.max_generation = @max(w.max_generation, generation);
        return e;
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
        w.ageContacts(dt);
        w.ageSignals(dt);
        w.resolveCollisions();

        w.status_timer += dt;
        if (w.status_timer >= 1.0) {
            w.status_timer = 0;
            w.updateWorldPhase();
            w.updateTerritories();
            w.updateSocietyStatuses();
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
        const rate = w.scarcity.regrowth() * w.phase.regrowth();
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
        // Starvation amplifies olfactory gain, as in real Drosophila DM1/DM4 ORNs.
        const hunger = std.math.clamp((80 - e.energy) / 60, 0, 1);
        const smell = e.genome.motorGene(.smell) * (1 + 0.8 * hunger) * (1 + 0.25 * e.skill(.navigation));

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

        // Taste + short-range food sight: prefer edible items under the entity,
        // and spot nearby edible food visually so starving entities don't wander blind.
        e.touching = null;
        e.visible_food = null;
        const reach = e.radius() + 5;
        const sight = if (w.forage_only) reach else 95 + 45 * e.skill(.navigation);
        var best_edible: f32 = reach;
        var best_any: f32 = reach;
        var best_sight: f32 = sight;
        var any_touch: ?u32 = null;
        for (w.resources.items, 0..) |r, ri| {
            if (r.amount <= 0) continue;
            const d = r.pos.dist(e.pos);
            if (d >= sight) continue;
            const edible = canEat(e, r.food);
            if (edible > 0) {
                if (d < best_sight) {
                    best_sight = d;
                    e.visible_food = r.pos;
                }
                if (d < best_edible) {
                    best_edible = d;
                    e.touching = @intCast(ri);
                }
            } else if (d < best_any) {
                best_any = d;
                any_touch = @intCast(ri);
            }
        }
        if (e.touching == null) e.touching = any_touch;
        var sugar: f32 = 0;
        var bitter: f32 = 0;
        if (e.touching) |ri| {
            const edible = canEat(e, w.resources.items[ri].food);
            if (edible > 0) {
                sugar = edible;
            } else {
                bitter = 1;
            }
        }

        e.senses = .{ .attr_L = attr[0], .attr_R = attr[1], .alarm_L = alarm[0], .alarm_R = alarm[1], .sugar = sugar, .bitter = bitter };
        e.motor = fly.step(w.circuit, e.genome.fly_gain, e.brain, e.senses);

        // Neighbours.
        e.enemy = null;
        e.ally = null;
        e.mate = null;
        e.enemies_near = 0;
        e.allies_near = 0;
        var close_allies: u32 = 0;
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
                if (d < 44) close_allies += 1;
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
        e.huddled = close_allies >= 2;
    }

    fn act(w: *World, i: usize, dt: f32) !void {
        const e = &w.entities.items[i];
        const g = &e.genome;
        const soc = societies[e.society];

        e.age += dt;
        e.since_meal += dt;
        e.repro_cooldown -= dt;
        e.escape_timer -= dt;
        e.bump_cooldown = @max(0, e.bump_cooldown - dt);

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

        // Stay near home when fed and territorial; adventurous or hungry entities roam far out into the wild.
        const hunger = std.math.clamp((80 - e.energy) / 60, 0, 1);
        if (e.energy < 35 and e.action != .flee) e.action = .forage;

        // Adventure / exploration drive + active communication + visual food pursuit + storm huddling.
        e.explore_timer = @max(0, e.explore_timer - dt);
        e.call_cooldown = @max(0, e.call_cooldown - dt);
        if (e.heard_timer > 0) {
            e.heard_timer -= dt;
            if (e.heard_timer <= 0) e.heard_kind = null;
        }

        // Act on heard signals from kin (food calls, danger warnings, storm rallies, mate calls).
        var acted_on_signal = false;
        if (!w.forage_only) {
            if (e.heard_kind) |hk| {
                const d_sig = e.pos.dist(e.heard_pos);
                switch (hk) {
                    .danger_call => {
                        if (d_sig < 145 and e.energy >= 40) {
                            const guard_like = e.role() == .guard or g.trait(.aggression) > 0.58;
                            if (guard_like and e.energy > 55) {
                                turn = steerTo(e.heading, e.pos, e.heard_pos, 4.0);
                            } else {
                                turn = steerTo(e.heading, e.pos, away(e.pos, e.heard_pos), 4.0);
                            }
                            acted_on_signal = true;
                        } else {
                            e.heard_kind = null;
                        }
                    },
                    .storm_rally => {
                        if (w.phase == .storm and !e.huddled and e.energy > 45 and d_sig > 22) {
                            turn = steerTo(e.heading, e.pos, e.heard_pos, 3.8);
                            acted_on_signal = true;
                        } else {
                            e.heard_kind = null;
                        }
                    },
                    .food_found => {
                        if (e.action == .forage and e.visible_food == null and e.odour < 0.22 and d_sig > 28) {
                            turn = steerTo(e.heading, e.pos, e.heard_pos, 3.4);
                            e.explore_target = null;
                            acted_on_signal = true;
                        } else if (d_sig <= 28 or e.feeding) {
                            e.heard_kind = null;
                        }
                    },
                    .mate_call => {
                        if (e.readyToMate() and e.mate == null and d_sig > 24 and target == null) {
                            turn = steerTo(e.heading, e.pos, e.heard_pos, 3.5);
                            acted_on_signal = true;
                        } else {
                            e.heard_kind = null;
                        }
                    },
                }
            }
        }

        const home_rect = w.territories[e.society];
        var seeking_shelter = false;
        if (!w.forage_only and !acted_on_signal and w.phase == .storm and e.energy > 50 and !e.feeding and e.action != .fight and e.action != .flee) {
            // During storms, non-starving beings huddle with nearby kin or pull back toward home cover.
            if (!e.huddled) {
                if (e.ally) |ai| {
                    if (e.ally_dist > 22) {
                        turn = steerTo(e.heading, e.pos, w.entities.items[ai].pos, 3.6);
                        seeking_shelter = true;
                    }
                } else if (!home_rect.contains(e.pos)) {
                    turn = steerTo(e.heading, e.pos, home_rect.center(), 3.2);
                    seeking_shelter = true;
                }
            }
        }

        if (!w.forage_only and !acted_on_signal and !seeking_shelter and target == null and e.action == .forage) {
            if (e.visible_food) |fpos| {
                // Visual lock onto nearby edible food when odour is faint or entity is hungry.
                if (e.odour < 0.14 or e.energy < 70) {
                    turn = steerTo(e.heading, e.pos, fpos, 4.2);
                    e.explore_target = null;
                }
            } else if (e.explore_target) |goal| {
                if (e.pos.dist(goal) < 40 or e.explore_timer <= 0) {
                    e.explore_target = null;
                    e.explore_timer = 3 + w.rng().float(f32) * 4;
                    e.addSkill(.navigation, 0.04);
                    e.genome.cog.learn(0.25);
                    if (w.rng().float(f32) < 0.25) _ = e.genome.cog.sproutFromExperience(w.rng());
                } else if (e.odour < 0.25) {
                    // Gently steer toward the frontier waypoint while still letting the fly brain
                    // take over as soon as it picks up a real food scent or trail.
                    turn = steerTo(e.heading, e.pos, goal, 2.5) + 0.5 * g.motorGene(.wander) * w.rng().floatNorm(f32);
                }
            } else if (e.energy < 55 and e.odour < 0.08) {
                // Urgent search sweep: starving entity smelling nothing sets out immediately instead of idling.
                var goal = w.randomIn(bounds.inset(90));
                var tries: usize = 0;
                while (goal.dist(e.pos) < 260 and tries < 5) : (tries += 1) {
                    goal = w.randomIn(bounds.inset(90));
                }
                e.explore_target = goal;
                e.explore_timer = 12;
            } else if (e.explore_timer <= 0 and e.odour < 0.16) {
                const wanderlust = (1 - g.trait(.territoriality)) * 0.55 + e.skill(.navigation) * 0.35 +
                    (if (e.energy > 95) @as(f32, 0.25) else if (e.energy < 45) @as(f32, 0.35) else 0);
                if (w.rng().float(f32) < wanderlust * 0.65) {
                    // Pick a distant frontier waypoint anywhere in the world.
                    var goal = w.randomIn(bounds.inset(90));
                    var tries: usize = 0;
                    while (goal.dist(e.pos) < 320 and tries < 5) : (tries += 1) {
                        goal = w.randomIn(bounds.inset(90));
                    }
                    e.explore_target = goal;
                    e.explore_timer = 14 + w.rng().float(f32) * 12;
                } else {
                    e.explore_timer = 2.0;
                }
            }
        } else if (target != null) {
            e.explore_target = null;
        }

        if (e.explore_target == null and !seeking_shelter and !acted_on_signal and e.visible_food == null) {
            const roam = 160 + 600 * (1 - g.trait(.territoriality)) + 500 * hunger;
            const home = home_rect.inset(-roam);
            if (!home.contains(e.pos)) turn = steerTo(e.heading, e.pos, home_rect.center(), 2.5);
        }

        // Resting / sleep state: tired, non-starving beings pause to recover fatigue and save energy.
        if (!w.forage_only) {
            const danger_near = e.enemies_near > 0 or e.heard_kind == .danger_call or e.action == .fight or e.action == .flee;
            if (e.resting) {
                if (e.fatigue <= 0.12 or e.energy < 38 or danger_near) e.resting = false;
            } else if (!danger_near and !e.feeding and e.energy > 48) {
                const rest_thresh: f32 = if (w.phase == .storm and e.huddled) 0.45 else if (e.energy > 95 and e.since_meal < 15) 0.65 else 0.85;
                if (e.fatigue >= rest_thresh) {
                    e.resting = true;
                    e.explore_target = null;
                }
            }
        } else {
            e.resting = false;
        }

        e.heading += if (e.resting) 0 else turn * dt;

        // Speed: DNp09 drives walking, MDN backs up, the giant fibre bolts, MN9 stops to feed.
        const base = 30 + 40 * g.trait(.speed);
        var speed = base * (0.5 + g.motorGene(.forward) * m.fwd);
        if (m.back > 0.3) speed = -0.4 * base;
        if (m.escape > 0.5 and e.escape_timer <= -1) e.escape_timer = 0.4;
        if (e.escape_timer > 0) speed = base * 2.5;
        if (e.action == .flee and e.enemy != null) speed = base * 1.2;
        if ((e.explore_target != null and e.odour < 0.25) or e.visible_food != null or seeking_shelter or acted_on_signal) {
            speed = @max(speed, base * (if (e.energy < 55) @as(f32, 1.05) else 0.95));
        }
        if (w.phase == .storm and e.huddled and !e.feeding and e.energy > 50) speed *= 0.45;
        if (e.resting) speed = 0;

        e.feeding = false;
        if (e.touching) |ri| {
            const r = &w.resources.items[ri];
            const value = canEat(e, r.food);
            const reach = e.radius() + 6;
            if (r.amount > 0 and value > 0 and r.pos.dist(e.pos) < reach) {
                // Slow on tasting edible food so MN9 has time to integrate before walking past.
                speed *= 0.45;
                if (m.feed > g.motorGene(.feed_threshold)) {
                    e.feeding = true;
                    e.explore_target = null;
                    e.heard_kind = null;
                    speed *= 0.2;
                    const fskill = e.skill(.foraging);
                    const bite = @min(r.amount, 30 * (1 + 0.35 * fskill) * m.feed * dt);
                    r.amount -= bite;
                    const gained = bite * value * (1 + 0.25 * fskill);
                    e.energy = @min(max_energy, e.energy + gained);
                    e.food_eaten += gained;
                    e.since_meal = 0;
                    e.addSkill(.foraging, bite * 0.004);
                    e.genome.cog.learn(gained * 0.06);
                    if (w.rng().float(f32) < bite * 0.006) _ = e.genome.cog.sproutFromExperience(w.rng());
                    // Food Call (waggle-dance style): share rich food locations with hungry kin nearby.
                    if (!w.forage_only and r.amount > 12 and e.call_cooldown <= 0 and (g.trait(.sociability) > 0.35 or e.skill(.care) > 0.2)) {
                        w.emitSignal(i, .food_found, r.pos);
                    }
                }
            }
        }

        // Other active society calls: danger warning (only when closely surrounded), storm rally, courtship call.
        if (!w.forage_only and e.call_cooldown <= 0) {
            if (e.enemies_near >= 3 and e.enemy_dist < 48) {
                if (e.enemy) |ei| w.emitSignal(i, .danger_call, w.entities.items[ei].pos);
            } else if (w.phase == .storm and e.huddled and (e.role() == .elder or e.role() == .caretaker or g.trait(.sociability) > 0.5)) {
                w.emitSignal(i, .storm_rally, e.pos);
            } else if (e.readyToMate() and e.mate == null and e.energy > 95 and g.trait(.sociability) > 0.4) {
                w.emitSignal(i, .mate_call, e.pos);
            }
        }
        // Physical crosswind during storms (huddled kin or home territory resist most of the wind).
        const wind_scale: f32 = if (w.phase == .storm and !w.forage_only)
            (if (e.huddled or e.resting) @as(f32, 0.2) else if (home_rect.contains(e.pos)) @as(f32, 0.5) else 1.0)
        else
            0;
        const step_x = (@cos(e.heading) * speed + e.bump_vel.x + 14 * wind_scale) * dt;
        const step_y = (@sin(e.heading) * speed + e.bump_vel.y + 4.5 * wind_scale) * dt;
        e.pos.x += step_x;
        e.pos.y += step_y;
        const moved = @sqrt(step_x * step_x + step_y * step_y);
        e.distance_traveled += moved;
        if (e.resting) {
            e.fatigue = @max(0, e.fatigue - 0.11 * dt);
        } else {
            const fatigue_gain = (0.008 + 0.0005 * @abs(speed)) * (1 - 0.35 * g.trait(.efficiency));
            e.fatigue = @min(1, e.fatigue + fatigue_gain * dt);
        }
        if (!e.feeding and !e.resting) {
            const nav_mult: f32 = if (home_rect.contains(e.pos)) 1.0 else 2.0;
            e.addSkill(.navigation, moved * 0.00014 * nav_mult);
        }
        const damp = @exp(-10 * dt);
        e.bump_vel.x *= damp;
        e.bump_vel.y *= damp;
        const edge = bounds.inset(e.radius());
        if (!edge.contains(e.pos)) {
            e.pos.x = std.math.clamp(e.pos.x, edge.x, edge.x + edge.w);
            e.pos.y = std.math.clamp(e.pos.y, edge.y, edge.y + edge.h);
            e.heading += std.math.pi;
        }

        // Lay a food trail for a while after eating.
        if (e.since_meal < 12) {
            w.field.deposit(trailChannel(e.society), e.pos.x, e.pos.y, g.trait(.trail_output) * 2.0 * @exp(-e.since_meal / 5) * dt);
        }

        // Metabolism, harsher in hard environments and during world storms; resting & huddling conserve energy.
        // Larger cognitive brains also carry a small real metabolic upkeep so only useful growth survives selection.
        const shelter_mult: f32 = if (w.phase == .storm and e.huddled) 0.55 else 1.0;
        const rest_mult: f32 = if (e.resting) 0.45 else 1.0;
        const harsh = (if (home_rect.contains(e.pos)) soc.harshness else 0.3) * w.phase.harshness() * shelter_mult;
        const move_cost = 0.01 * (1 - 0.35 * e.skill(.navigation)) * @abs(speed);
        const brain_cost = 0.004 * @as(f32, @floatFromInt(g.cog.hidden_count)) + 0.0003 * @as(f32, @floatFromInt(g.cog.activeSynapses()));
        const drain = (0.5 + 0.6 * g.trait(.speed) - 0.4 * g.trait(.efficiency) + move_cost + brain_cost) * (1 + 0.5 * harsh) * rest_mult;
        e.energy -= drain * dt;
        if (e.energy < 25) e.genome.cog.learn(-0.08 * dt);

        // Combat (within physical reach); combat skill improves both offense and defense.
        if (e.action == .fight) {
            if (e.enemy) |oi| {
                const o = &w.entities.items[oi];
                if (o.dead == null and o.pos.dist(e.pos) < e.radius() + o.radius() + 4) {
                    const atk = (8 + 22 * g.trait(.aggression)) * (1 + 0.4 * e.skill(.combat));
                    const dmg = atk * (1 - 0.3 * o.skill(.combat)) * dt;
                    o.energy -= dmg;
                    e.energy -= 3 * dt;
                    e.addSkill(.combat, dt * 0.05);
                    o.addSkill(.combat, dt * 0.03);
                    o.genome.cog.learn(-dmg * 0.12);
                    if (!w.forage_only and o.call_cooldown <= 0) w.emitSignal(oi, .danger_call, e.pos);
                    w.field.deposit(alarmChannel(o.society), o.pos.x, o.pos.y, dmg * 0.6);
                    if (o.energy <= 0 and o.dead == null) {
                        e.kills += 1;
                        e.addSkill(.combat, 0.08);
                        e.genome.cog.learn(0.6);
                        try w.kill(oi, .killed);
                    }
                }
            }
        }

        // Any two ready adults that touch/meet can breed; the mate action makes them seek each other.
        if (e.mate) |oi| {
            const o = &w.entities.items[oi];
            if (o.pos.dist(e.pos) < e.radius() + o.radius() + 6 and e.readyToMate() and o.readyToMate() and w.entities.items.len < max_population) {
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
        child.lineage = if (a.society != b.society) child.id else if (w.rng().boolean()) a.lineage else b.lineage;
        child.energy = 50;
        child.since_meal = 0;

        // Pass down learned skills: parents' care skill & sociability raise transfer fidelity.
        const avg_care = 0.5 * (a.skill(.care) + b.skill(.care));
        const avg_soc = 0.5 * (a.genome.trait(.sociability) + b.genome.trait(.sociability));
        const transfer = std.math.clamp(0.45 + 0.25 * avg_care + 0.1 * avg_soc, 0.35, 0.78);
        for (&child.skills, a.skills, b.skills) |*cs, sa, sb| {
            const jitter = 1 + 0.08 * w.rng().floatNorm(f32);
            cs.* = std.math.clamp(0.5 * (sa + sb) * transfer * jitter, 0, 1);
        }

        w.max_generation = @max(w.max_generation, child.generation);
        const st = &w.stats[society];
        st.births += 1;
        if (child.generation > st.max_gen) {
            st.max_gen = child.generation;
            if (st.max_gen >= st.gen_milestone) {
                w.pushEvent(society, .milestone_gen, st.max_gen);
                st.gen_milestone = if (st.gen_milestone < 5) 5 else st.gen_milestone + 5;
            }
        }
        if (child.hybrid and !st.had_hybrid) {
            st.had_hybrid = true;
            w.pushEvent(society, .first_hybrid, child.generation);
        }
        w.recordGeneration(child);

        for ([_]usize{ ai, bi }) |pi| {
            const p = &w.entities.items[pi];
            p.energy -= 25;
            p.repro_cooldown = 30;
            p.children += 1;
            p.addSkill(.care, 0.05);
            p.genome.cog.learn(0.8);
        }
    }

    fn recordGeneration(w: *World, e: *const Entity) void {
        const idx = @min(e.generation -| 1, max_gen_records - 1);
        const rec = &w.gen_records[idx];
        rec.gen = e.generation;
        rec.births += 1;
        for (&rec.skill_sum, e.skills) |*sum, s| sum.* += s;
        rec.trait_eff_sum += e.genome.trait(.efficiency);
        rec.trait_aggr_sum += e.genome.trait(.aggression);
        rec.trait_adapt_sum += e.genome.trait(.adaptability);
        rec.neuron_sum += @floatFromInt(e.genome.cog.totalNeurons());
        rec.synapse_sum += @floatFromInt(e.genome.cog.activeSynapses());
        if (idx + 1 > w.gen_record_count) w.gen_record_count = idx + 1;
    }

    fn pushEvent(w: *World, society: u8, kind: EventKind, value: u32) void {
        const ev = WorldEvent{ .time = w.time, .society = society, .kind = kind, .value = value };
        if (w.event_count < max_events) {
            w.events[w.event_count] = ev;
            w.event_count += 1;
        } else {
            std.mem.copyForwards(WorldEvent, w.events[0 .. max_events - 1], w.events[1..]);
            w.events[max_events - 1] = ev;
        }
    }

    fn updateWorldPhase(w: *World) void {
        const t = @mod(w.time, cycle_length);
        const next: WorldPhase = if (t < 145) .calm else if (t < 235) .bloom else .storm;
        if (next != w.phase) {
            w.phase = next;
            if (next == .bloom) w.pushEvent(0, .world_bloom, 0);
            if (next == .storm) w.pushEvent(0, .world_storm, 0);
        }
    }

    /// Gently shift and resize each society's living territory toward where its population actually lives.
    fn updateTerritories(w: *World) void {
        const safe = bounds.inset(40);
        for (0..society_count) |si| {
            var sx: f32 = 0;
            var sy: f32 = 0;
            var n: f32 = 0;
            for (w.entities.items) |e| {
                if (e.dead != null or e.society != si) continue;
                sx += e.pos.x;
                sy += e.pos.y;
                n += 1;
            }
            if (n < 5) continue;
            const cx = sx / n;
            const cy = sy / n;
            // Territory expands modestly when thriving and contracts when small.
            const target_w = std.math.clamp(360 + n * 3.0, 340, 680);
            const target_h = std.math.clamp(300 + n * 2.4, 280, 560);
            const cur = &w.territories[si];
            const cur_c = cur.center();
            const nw = cur.w + (target_w - cur.w) * 0.03;
            const nh = cur.h + (target_h - cur.h) * 0.03;
            const nx = std.math.clamp(cur_c.x + (cx - cur_c.x) * 0.035 - nw * 0.5, safe.x, safe.x + safe.w - nw);
            const ny = std.math.clamp(cur_c.y + (cy - cur_c.y) * 0.035 - nh * 0.5, safe.y, safe.y + safe.h - nh);
            cur.* = .{ .x = nx, .y = ny, .w = nw, .h = nh };
        }
        // Keep living territories from collapsing completely on top of one another while still allowing border clashes.
        for (0..society_count) |a| {
            if (w.stats[a].status == .extinct) continue;
            for (a + 1..society_count) |b| {
                if (w.stats[b].status == .extinct) continue;
                const ca = w.territories[a].center();
                const cb = w.territories[b].center();
                const dx = cb.x - ca.x;
                const dy = cb.y - ca.y;
                const d = @sqrt(dx * dx + dy * dy);
                if (d < 360 and d > 1e-3) {
                    const push = (360 - d) * 0.03;
                    const ux = dx / d;
                    const uy = dy / d;
                    w.territories[a].x = std.math.clamp(w.territories[a].x - ux * push, safe.x, safe.x + safe.w - w.territories[a].w);
                    w.territories[a].y = std.math.clamp(w.territories[a].y - uy * push, safe.y, safe.y + safe.h - w.territories[a].h);
                    w.territories[b].x = std.math.clamp(w.territories[b].x + ux * push, safe.x, safe.x + safe.w - w.territories[b].w);
                    w.territories[b].y = std.math.clamp(w.territories[b].y + uy * push, safe.y, safe.y + safe.h - w.territories[b].h);
                }
            }
        }
    }

    fn updateSocietyStatuses(w: *World) void {
        for (0..society_count) |si| {
            const pop = w.population(si);
            const st = &w.stats[si];
            const prev = st.status;
            if (pop > st.peak_pop) st.peak_pop = pop;
            const next: SocietyStatus = if (pop == 0)
                .extinct
            else if (pop <= 5)
                .endangered
            else if (pop <= 12)
                .struggling
            else if (pop >= 40)
                .thriving
            else
                .stable;
            st.status = next;

            if (next == .extinct and prev != .extinct) {
                st.extinct_time = w.time;
                w.pushEvent(@intCast(si), .extinct, st.max_gen);
            } else if (next == .endangered and prev != .endangered and prev != .extinct) {
                w.pushEvent(@intCast(si), if (pop <= 3) .critical else .endangered, pop);
            } else if ((prev == .endangered or prev == .struggling) and pop >= 15) {
                w.pushEvent(@intCast(si), .recovered, pop);
            }
            if (pop >= st.boom_milestone) {
                w.pushEvent(@intCast(si), .boom, pop);
                st.boom_milestone += 50;
            }
            if (!st.had_hybrid_majority and pop >= 10) {
                var hyb: u32 = 0;
                for (w.entities.items) |e| {
                    if (e.dead == null and e.society == si and e.hybrid) hyb += 1;
                }
                if (hyb * 2 >= pop) {
                    st.had_hybrid_majority = true;
                    w.pushEvent(@intCast(si), .hybrid_majority, pop);
                }
            }
        }

        // Detect living territory border overlap between active societies.
        if (w.clash_cooldown > 0) {
            w.clash_cooldown = @max(0, w.clash_cooldown - 1.0);
        } else {
            outer: for (0..society_count) |a| {
                if (w.stats[a].status == .extinct) continue;
                for (a + 1..society_count) |b| {
                    if (w.stats[b].status == .extinct) continue;
                    const ra = w.territories[a];
                    const rb = w.territories[b];
                    const overlap = ra.x < rb.x + rb.w and ra.x + ra.w > rb.x and ra.y < rb.y + rb.h and ra.y + ra.h > rb.y;
                    if (overlap) {
                        w.pushEvent(@intCast(a), .territory_clash, @intCast(b));
                        w.clash_cooldown = 90;
                        break :outer;
                    }
                }
            }
        }
    }

    fn ageContacts(w: *World, dt: f32) void {
        var i: usize = 0;
        while (i < w.contact_count) {
            w.contacts[i].age += dt;
            if (w.contacts[i].age >= contact_duration) {
                w.contact_count -= 1;
                w.contacts[i] = w.contacts[w.contact_count];
                continue;
            }
            i += 1;
        }
    }

    fn ageSignals(w: *World, dt: f32) void {
        var i: usize = 0;
        while (i < w.signal_count) {
            w.signals[i].age += dt;
            if (w.signals[i].age >= signal_duration) {
                w.signal_count -= 1;
                w.signals[i] = w.signals[w.signal_count];
                continue;
            }
            i += 1;
        }
    }

    /// Broadcast an acoustic/dance signal to nearby kin of the same society.
    fn emitSignal(w: *World, sender_idx: usize, kind: SignalKind, target: Vec2) void {
        const sender = &w.entities.items[sender_idx];
        const soc = sender.society;
        const pos = sender.pos;
        const radius = if (kind == .danger_call)
            120 + 60 * sender.genome.trait(.sociability)
        else
            180 + 140 * sender.genome.trait(.sociability) + 100 * sender.skill(.care);
        sender.call_cooldown = if (kind == .danger_call) 10.0 else 4.5;
        sender.last_sent = kind;
        sender.energy = @max(1, sender.energy - 0.25);
        sender.addSkill(.care, 0.02);
        w.stats[soc].signals_sent += 1;

        const sig = Signal{ .pos = pos, .target = target, .kind = kind, .society = soc, .radius = radius };
        if (w.signal_count < w.signals.len) {
            w.signals[w.signal_count] = sig;
            w.signal_count += 1;
        } else {
            var oldest: usize = 0;
            for (1..w.signals.len) |k| if (w.signals[k].age > w.signals[oldest].age) {
                oldest = k;
            };
            w.signals[oldest] = sig;
        }

        const sender_id = sender.id;
        for (w.entities.items) |*o| {
            if (o.dead != null or o.id == sender_id or o.society != soc) continue;
            if (o.pos.dist(pos) > radius) continue;
            switch (kind) {
                .food_found => {
                    if (o.energy < 95 and !o.feeding and o.action != .fight and o.action != .flee and o.heard_kind != .danger_call) {
                        o.heard_kind = .food_found;
                        o.heard_pos = target;
                        o.heard_timer = 10;
                        w.stats[soc].signals_acted += 1;
                    }
                },
                .danger_call => {
                    if (o.energy >= 40) {
                        o.heard_kind = .danger_call;
                        o.heard_pos = target;
                        o.heard_timer = 3.5;
                        o.action_timer = 0;
                        w.stats[soc].signals_acted += 1;
                    }
                },
                .storm_rally => {
                    if (w.phase == .storm and !o.huddled and o.energy > 45) {
                        o.heard_kind = .storm_rally;
                        o.heard_pos = target;
                        o.heard_timer = 8;
                        w.stats[soc].signals_acted += 1;
                    }
                },
                .mate_call => {
                    if (o.readyToMate() and o.mate == null and o.heard_kind == null) {
                        o.heard_kind = .mate_call;
                        o.heard_pos = target;
                        o.heard_timer = 7;
                        w.stats[soc].signals_acted += 1;
                    }
                },
            }
        }
    }

    fn addContact(w: *World, pos: Vec2, kind: ContactKind, society: u8) void {
        if (w.contact_count < w.contacts.len) {
            w.contacts[w.contact_count] = .{ .pos = pos, .kind = kind, .society = society };
            w.contact_count += 1;
        } else {
            // Replace the oldest active contact ripple.
            var oldest: usize = 0;
            for (1..w.contacts.len) |i| {
                if (w.contacts[i].age > w.contacts[oldest].age) oldest = i;
            }
            w.contacts[oldest] = .{ .pos = pos, .kind = kind, .society = society };
        }
    }

    /// Separate overlapping entities so bodies stay solid, and trigger tactile reactions on contact.
    fn resolveCollisions(w: *World) void {
        const items = w.entities.items;
        const n = items.len;
        if (n < 2) return;

        for (0..3) |iter| {
            for (0..n) |i| {
                const a = &items[i];
                if (a.dead != null) continue;
                const ra = a.radius();
                for (i + 1..n) |j| {
                    const b = &items[j];
                    if (b.dead != null) continue;
                    const rb = b.radius();
                    const min_dist = ra + rb;
                    const dx = b.pos.x - a.pos.x;
                    if (@abs(dx) >= min_dist) continue;
                    const dy = b.pos.y - a.pos.y;
                    if (@abs(dy) >= min_dist) continue;
                    const d2 = dx * dx + dy * dy;
                    if (d2 >= min_dist * min_dist) continue;

                    var nx: f32 = undefined;
                    var ny: f32 = undefined;
                    var dist: f32 = undefined;
                    if (d2 > 1e-6) {
                        dist = @sqrt(d2);
                        nx = dx / dist;
                        ny = dy / dist;
                    } else {
                        const angle = @as(f32, @floatFromInt((a.id ^ b.id) % 360)) * (std.math.tau / 360.0);
                        dist = 0;
                        nx = @cos(angle);
                        ny = @sin(angle);
                    }

                    const pen = min_dist - dist;
                    const ma = ra * ra;
                    const mb = rb * rb;
                    const inv = 1.0 / (ma + mb);
                    a.pos.x -= nx * pen * mb * inv;
                    a.pos.y -= ny * pen * mb * inv;
                    b.pos.x += nx * pen * ma * inv;
                    b.pos.y += ny * pen * ma * inv;

                    const edge_a = bounds.inset(ra);
                    a.pos.x = std.math.clamp(a.pos.x, edge_a.x, edge_a.x + edge_a.w);
                    a.pos.y = std.math.clamp(a.pos.y, edge_a.y, edge_a.y + edge_a.h);
                    const edge_b = bounds.inset(rb);
                    b.pos.x = std.math.clamp(b.pos.x, edge_b.x, edge_b.x + edge_b.w);
                    b.pos.y = std.math.clamp(b.pos.y, edge_b.y, edge_b.y + edge_b.h);

                    if (iter == 0 and (a.bump_cooldown <= 0 or b.bump_cooldown <= 0)) {
                        w.onTouch(a, b, nx, ny);
                    }
                }
            }
        }
    }

    /// Physical & behavioural reaction when two entities bump into each other.
    fn onTouch(w: *World, a: *Entity, b: *Entity, nx: f32, ny: f32) void {
        const mid = Vec2{ .x = (a.pos.x + b.pos.x) * 0.5, .y = (a.pos.y + b.pos.y) * 0.5 };
        a.bump_cooldown = 0.45;
        b.bump_cooldown = 0.45;

        // Gentle elastic deflection so bodies slide around each other naturally.
        const away_a = std.math.atan2(-ny, -nx);
        const away_b = std.math.atan2(ny, nx);

        if (a.society == b.society) {
            // Kin slide smoothly past each other along the tangent instead of bouncing off their trail.
            const tx = -ny;
            const ty = nx;
            const a_side: f32 = if (@cos(a.heading) * tx + @sin(a.heading) * ty >= 0) 1 else -1;
            const b_side: f32 = if (@cos(b.heading) * tx + @sin(b.heading) * ty >= 0) 1 else -1;
            a.bump_vel.x += tx * a_side * 8 - nx * 4;
            a.bump_vel.y += ty * a_side * 8 - ny * 4;
            b.bump_vel.x += tx * b_side * 8 + nx * 4;
            b.bump_vel.y += ty * b_side * 8 + ny * 4;

            // Mentorship: experienced adults/elders pass a bit of their learned skills to less-skilled kin.
            mentorKin(a, b);
            mentorKin(b, a);

            if (a.readyToMate() and b.readyToMate()) {
                w.addContact(mid, .courtship, a.society);
                return;
            }
            // Trophallaxis: a well-fed, sociable kin shares a small bit of energy with a hungry one.
            if (tryShareFood(w, a, b, mid) or tryShareFood(w, b, a, mid)) return;

            // Antennation: a recently fed kin leaves a quick trail cue for a hungry kin.
            if (a.since_meal < 8 and b.since_meal > 10) {
                w.field.deposit(trailChannel(a.society), mid.x, mid.y, 0.8);
                a.addSkill(.care, 0.015);
                w.addContact(mid, .kin_greet, a.society);
            } else if (b.since_meal < 8 and a.since_meal > 10) {
                w.field.deposit(trailChannel(b.society), mid.x, mid.y, 0.8);
                b.addSkill(.care, 0.015);
                w.addContact(mid, .kin_greet, b.society);
            }
            return;
        }

        // Rival contact: immediate wake + re-decision + alarm pheromone into both fly circuits.
        a.resting = false;
        b.resting = false;
        a.action_timer = 0;
        b.action_timer = 0;
        a.addSkill(.combat, 0.02);
        b.addSkill(.combat, 0.02);
        w.field.deposit(alarmChannel(a.society), mid.x, mid.y, 1.5);
        w.field.deposit(alarmChannel(b.society), mid.x, mid.y, 1.5);

        const a_aggr = a.action == .fight or a.genome.trait(.aggression) > 0.65;
        const b_aggr = b.action == .fight or b.genome.trait(.aggression) > 0.65;
        const a_timid = a.action == .flee or a.genome.trait(.aggression) < 0.35;
        const b_timid = b.action == .flee or b.genome.trait(.aggression) < 0.35;

        const push_a: f32 = if (b_aggr) 55 else if (a_timid) 65 else 35;
        const push_b: f32 = if (a_aggr) 55 else if (b_timid) 65 else 35;
        a.bump_vel.x -= nx * push_a;
        a.bump_vel.y -= ny * push_a;
        b.bump_vel.x += nx * push_b;
        b.bump_vel.y += ny * push_b;

        if (a_aggr) {
            a.heading = nudgeAngle(a.heading, away_b, 0.55);
        } else if (a_timid) {
            a.heading = nudgeAngle(a.heading, away_a, 0.85);
            a.escape_timer = @max(a.escape_timer, 0.25);
        } else {
            a.heading = nudgeAngle(a.heading, away_a, 0.45);
        }

        if (b_aggr) {
            b.heading = nudgeAngle(b.heading, away_a, 0.55);
        } else if (b_timid) {
            b.heading = nudgeAngle(b.heading, away_b, 0.85);
            b.escape_timer = @max(b.escape_timer, 0.25);
        } else {
            b.heading = nudgeAngle(b.heading, away_b, 0.45);
        }

        const kind: ContactKind = if (a_aggr or b_aggr) .rival_clash else if (a_timid or b_timid) .startle else .rival_clash;
        w.addContact(mid, kind, if (a_aggr) a.society else b.society);
    }

    fn tryShareFood(w: *World, donor: *Entity, receiver: *Entity, mid: Vec2) bool {
        if (donor.energy > 105 and receiver.energy < 75 and donor.genome.trait(.sociability) > 0.45) {
            const gift: f32 = 6 + 4 * donor.skill(.care);
            donor.energy -= gift;
            receiver.energy = @min(max_energy, receiver.energy + gift);
            receiver.since_meal = @min(receiver.since_meal, 4);
            donor.addSkill(.care, 0.06);
            donor.genome.cog.learn(0.35);
            receiver.genome.cog.learn(0.4);
            w.field.deposit(trailChannel(donor.society), mid.x, mid.y, 1.0);
            w.addContact(mid, .share_food, donor.society);
            return true;
        }
        return false;
    }

    fn mentorKin(mentor: *Entity, student: *Entity) void {
        if (!mentor.mature()) return;
        const rate = 0.06 * (0.6 + mentor.skill(.care) + if (mentor.role() == .elder) @as(f32, 0.5) else 0);
        var taught = false;
        for (0..skill_count) |si| {
            const diff = mentor.skills[si] - student.skills[si];
            if (diff > 0.08) {
                student.addSkill(@fromBackingInt(@intCast(si)), diff * rate);
                taught = true;
            }
        }
        if (taught) mentor.addSkill(.care, 0.015);
    }
};

fn initTerritories() [society_count]Rect {
    var out: [society_count]Rect = undefined;
    for (societies, 0..) |s, i| out[i] = s.territory;
    return out;
}

fn nudgeAngle(current: f32, target: f32, amount: f32) f32 {
    const diff = @mod(target - current + std.math.pi, std.math.tau) - std.math.pi;
    return current + diff * amount;
}

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
