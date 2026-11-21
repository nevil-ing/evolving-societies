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
    feast,
    abundant,
    normal,
    scarce,
    famine,
    none,

    pub fn regrowth(s: Scarcity) f32 {
        return switch (s) {
            .feast => 5.0,
            .abundant => 2.0,
            .normal => 1.0,
            .scarce => 0.5,
            .famine => 0.2,
            .none => 0.0,
        };
    }
};

pub const Resource = struct {
    pos: Vec2,
    food: FoodType,
    amount: f32,
    patch: ?u16,
    corpse: bool = false,
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
    building, // faster construction/repair of shelters & food caches
    toolcraft, // crafting spears/baskets & hunting wild prey with tools
};
pub const skill_count = @typeInfo(Skill).@"enum".field_names.len;

pub const Role = enum(u8) {
    juvenile,
    novice,
    forager,
    scout,
    guard,
    caretaker,
    builder,
    hunter,
    elder,
};
pub const role_count = @typeInfo(Role).@"enum".field_names.len;

pub const LifeStage = enum(u8) { infant, juvenile, adult, elder };

pub const MaterialKind = enum(u8) { wood, stone };

pub const Material = struct {
    pos: Vec2,
    kind: MaterialKind,
    amount: f32,
};

pub const CarryItem = enum(u8) { none, wood, stone };
pub const ToolKind = enum(u8) { none, spear, basket };

pub const StructureKind = enum(u8) { shelter, cache };

pub const Structure = struct {
    pos: Vec2,
    society: u8,
    kind: StructureKind,
    progress: f32, // 0..100, functional once >= 100
    integrity: f32 = 100,
    stored_food: f32 = 0, // up to 240 for .cache
    builder_id: u32,

    pub fn complete(s: *const Structure) bool {
        return s.progress >= 100;
    }
    pub fn radius(s: *const Structure) f32 {
        return switch (s.kind) {
            .shelter => 48,
            .cache => 34,
        };
    }
};
pub const max_structures_per_society = 8;
pub const max_cache_food: f32 = 240;

pub const Prey = struct {
    pos: Vec2,
    heading: f32,
    hp: f32 = 90,
    max_hp: f32 = 90,
    flee_timer: f32 = 0,
    stagger_timer: f32 = 0,

    pub fn radius(_: *const Prey) f32 {
        return 12;
    }
};

pub const Predator = struct {
    pos: Vec2,
    heading: f32,
    hp: f32 = 160,
    max_hp: f32 = 160,
    energy: f32 = 100,
    lunge_timer: f32 = 0,
    flee_timer: f32 = 0,
    stagger_timer: f32 = 0,
    sated_timer: f32 = 0,
    kills: u32 = 0,

    pub fn radius(_: *const Predator) f32 {
        return 13;
    }
};

pub const MemoryKind = enum(u8) { food, material, shelter, danger, prey };

pub const Memory = struct {
    kind: MemoryKind = .food,
    pos: Vec2 = .{ .x = 0, .y = 0 },
    confidence: f32 = 0, // 0 = empty, decays slowly over minutes
    age: f32 = 0,
};
pub const max_memories = 6;

pub const SocialBond = struct {
    other_id: u32 = 0,
    trust: f32 = 0, // -1 (distrusted attacker) .. +1 (trusted ally)
};
pub const max_bonds = 4;

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

pub const EventKind = enum(u8) { endangered, critical, extinct, recovered, boom, milestone_gen, first_hybrid, hybrid_majority, territory_clash, cannibalism, tool_discovered, building_discovered, predator_slain, cache_raided, world_bloom, world_storm };

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
    cannibal_kills: u32 = 0,
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
    carrying: CarryItem = .none,
    tool: ToolKind = .none,
    tool_durability: f32 = 0,
    craft_cooldown: f32 = 0,
    memories: [max_memories]Memory = @splat(.{}),
    bonds: [max_bonds]SocialBond = @splat(.{}),
    recalling: ?MemoryKind = null,

    // Refreshed every brain tick.
    touching: ?u32 = null,
    visible_food: ?Vec2 = null,
    huddled: bool = false,
    in_shelter: bool = false,
    cannibal_target: bool = false,
    near_material: ?u32 = null,
    near_structure: ?u32 = null,
    near_cache: ?u32 = null,
    enemy_structure: ?u32 = null,
    near_prey: ?u32 = null,
    near_predator: ?u32 = null,
    predator_dist: f32 = sense_range,
    intruder_in_home: bool = false,
    enemy: ?u32 = null,
    enemy_dist: f32 = 0,
    enemies_near: u32 = 0,
    ally: ?u32 = null,
    ally_dist: f32 = 0,
    allies_near: u32 = 0,
    mate: ?u32 = null,

    dead: ?Death = null,

    pub fn stage(e: *const Entity) LifeStage {
        if (e.age < infant_age) return .infant;
        if (e.age < maturity_age) return .juvenile;
        if (e.age >= e.lifespan * elder_frac) return .elder;
        return .adult;
    }
    pub fn radius(e: *const Entity) f32 {
        return switch (e.stage()) {
            .infant => 8 * (0.46 + 0.16 * std.math.clamp(e.age / infant_age, 0, 1)),
            .juvenile => 8 * (0.62 + 0.36 * std.math.clamp((e.age - infant_age) / (maturity_age - infant_age), 0, 1)),
            .adult => 8.0,
            .elder => 8.5,
        };
    }
    pub fn mature(e: *const Entity) bool {
        return e.age >= maturity_age;
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
        if (e.stage() == .elder or (e.age > 600 and total >= 1.1)) return .elder;
        if (e.tool == .spear and e.skill(.toolcraft) >= 0.14) return .hunter;
        if (e.skill(.building) >= 0.22 and e.skill(.building) >= e.skill(.toolcraft)) return .builder;
        if (e.skill(.toolcraft) >= 0.22) return .hunter;
        if (best_v < 0.18) return .novice;
        return switch (@as(Skill, @fromBackingInt(@intCast(best_i)))) {
            .foraging => .forager,
            .navigation => .scout,
            .combat => .guard,
            .care => .caretaker,
            .building => .builder,
            .toolcraft => .hunter,
        };
    }
    pub fn remember(e: *Entity, kind: MemoryKind, pos: Vec2, strength: f32) void {
        var weakest: usize = 0;
        var weak_conf: f32 = 2.0;
        for (&e.memories, 0..) |*m, idx| {
            if (m.confidence > 0 and m.kind == kind and m.pos.dist(pos) < 110) {
                m.pos.x = m.pos.x * 0.65 + pos.x * 0.35;
                m.pos.y = m.pos.y * 0.65 + pos.y * 0.35;
                m.confidence = @min(1.0, @max(m.confidence, strength) + 0.15);
                m.age = 0;
                return;
            }
            if (m.confidence < weak_conf) {
                weak_conf = m.confidence;
                weakest = idx;
            }
        }
        if (strength >= weak_conf or weak_conf <= 0.01) {
            e.memories[weakest] = .{ .kind = kind, .pos = pos, .confidence = std.math.clamp(strength, 0, 1), .age = 0 };
        }
    }
    pub fn recall(e: *const Entity, kind: MemoryKind, min_conf: f32) ?usize {
        var best: ?usize = null;
        var best_score: f32 = min_conf;
        for (e.memories, 0..) |m, idx| {
            if (m.kind == kind and m.confidence > best_score) {
                best_score = m.confidence;
                best = idx;
            }
        }
        return best;
    }
    pub fn activeMemories(e: *const Entity) u32 {
        var n: u32 = 0;
        for (e.memories) |m| if (m.confidence > 0.1) {
            n += 1;
        };
        return n;
    }
    pub fn adjustTrust(e: *Entity, other_id: u32, delta: f32) void {
        if (other_id == 0 or other_id == e.id) return;
        var slot: usize = 0;
        var weakest: f32 = 2.0;
        for (&e.bonds, 0..) |*b, idx| {
            if (b.other_id == other_id) {
                b.trust = std.math.clamp(b.trust + delta, -1, 1);
                return;
            }
            if (b.other_id == 0) {
                b.* = .{ .other_id = other_id, .trust = std.math.clamp(delta, -1, 1) };
                return;
            }
            if (@abs(b.trust) < weakest) {
                weakest = @abs(b.trust);
                slot = idx;
            }
        }
        if (@abs(delta) >= weakest) {
            e.bonds[slot] = .{ .other_id = other_id, .trust = std.math.clamp(delta, -1, 1) };
        }
    }
    pub fn trustOf(e: *const Entity, other_id: u32) f32 {
        for (e.bonds) |b| if (b.other_id == other_id) return b.trust;
        return 0;
    }
    pub fn bondCount(e: *const Entity) u32 {
        var n: u32 = 0;
        for (e.bonds) |b| if (b.other_id != 0 and @abs(b.trust) > 0.1) {
            n += 1;
        };
        return n;
    }
};

pub const infant_age: f32 = 60; // 1 min newborn/infant stage
pub const maturity_age: f32 = 240; // 4 min to reach reproductive adulthood (for 1-2h lifespans)
pub const elder_frac: f32 = 0.25; // elder stage begins at 25% of lifespan (15-30 min)
pub const max_energy: f32 = 150;
pub const brain_hz: f32 = 20;
pub const history_len = 400;
const sense_range: f32 = 160;
const grid_cell: f32 = 80;
const grid_cols: usize = 25; // bounds.w (2000) / 80
const grid_rows: usize = 20; // bounds.h (1600) / 80
const grid_cells: usize = grid_cols * grid_rows;
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
    cannibal_kills: u32 = 0,
    had_cannibalism: bool = false,
    tools_crafted: u32 = 0,
    structures_built: u32 = 0,
    prey_hunted: u32 = 0,
    predators_slain: u32 = 0,
    raids_suffered: u32 = 0,
    discovered_tools: bool = false,
    discovered_building: bool = false,
};

pub const World = struct {
    gpa: std.mem.Allocator,
    prng: std.Random.DefaultPrng,
    circuit: *const fly.Circuit,
    entities: std.ArrayList(Entity) = .empty,
    resources: std.ArrayList(Resource) = .empty,
    patches: std.ArrayList(Patch) = .empty,
    materials: std.ArrayList(Material) = .empty,
    structures: std.ArrayList(Structure) = .empty,
    prey: std.ArrayList(Prey) = .empty,
    predators: std.ArrayList(Predator) = .empty,
    material_timer: f32 = 0,
    prey_timer: f32 = 0,
    predator_timer: f32 = 0,
    raid_cooldown: f32 = 0,
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
    phase_offset: f32 = 0,
    territories: [society_count]Rect = initTerritories(),
    events: [max_events]WorldEvent = undefined,
    event_count: usize = 0,
    gen_records: [max_gen_records]GenRecord = @splat(.{}),
    gen_record_count: usize = 0,
    contacts: [64]ContactEvent = undefined,
    contact_count: usize = 0,
    signals: [48]Signal = undefined,
    signal_count: usize = 0,
    grid_head: [grid_cells]i32 = @splat(-1),
    grid_next: std.ArrayList(i32) = .empty,
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
        w.materials.clearRetainingCapacity();
        w.structures.clearRetainingCapacity();
        w.prey.clearRetainingCapacity();
        w.predators.clearRetainingCapacity();
        w.material_timer = 0;
        w.prey_timer = 0;
        w.predator_timer = 0;
        w.raid_cooldown = 0;
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
        w.phase_offset = 0;
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
            // Raw materials: stone outcrops & timber scattered in and around each homeland.
            const stone_n: usize = if (si == 1) 2 else 4;
            const wood_n: usize = 6 - stone_n;
            for (0..stone_n) |_| try w.materials.append(w.gpa, .{ .pos = w.randomIn(s.territory.inset(25)), .kind = .stone, .amount = 45 });
            for (0..wood_n) |_| try w.materials.append(w.gpa, .{ .pos = w.randomIn(s.territory.inset(25)), .kind = .wood, .amount = 45 });

            for (0..25) |k| {
                const g = try gen.Genome.random(w.gpa, w.rng(), w.circuit.types);
                const e = try w.addEntity(@intCast(si), w.randomIn(s.territory.inset(40)), g);
                // Natural starting age pyramid: ~72% young adults, ~28% growing youths.
                e.age = if (k < 18)
                    maturity_age + w.rng().float(f32) * 180
                else
                    infant_age + w.rng().float(f32) * (maturity_age - infant_age);
                e.lineage = e.id;
                w.recordGeneration(e);
            }
        }
        // Frontier raw materials & wild prey for exploration, building, and tool-hunting.
        for (0..18) |_| try w.materials.append(w.gpa, .{ .pos = w.randomIn(wild), .kind = .wood, .amount = 45 });
        for (0..18) |_| try w.materials.append(w.gpa, .{ .pos = w.randomIn(wild), .kind = .stone, .amount = 45 });
        try w.spawnPrey(5);
        try w.spawnPredators(2);
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

    pub fn foodCount(w: *const World) u32 {
        var n: u32 = 0;
        for (w.resources.items) |r| {
            if (r.amount > 0 and !r.corpse) n += 1;
        }
        return n;
    }

    pub fn corpseCount(w: *const World) u32 {
        var n: u32 = 0;
        for (w.resources.items) |r| {
            if (r.amount > 0 and r.corpse) n += 1;
        }
        return n;
    }

    pub fn phaseClock(w: *const World) f32 {
        return w.time + w.phase_offset;
    }

    /// Immediately jump the world weather cycle to the start of `p`.
    pub fn setPhase(w: *World, p: WorldPhase) void {
        const target: f32 = switch (p) {
            .calm => 0,
            .bloom => 145,
            .storm => 235,
        };
        var off = target - @mod(w.time, cycle_length);
        if (off < 0) off += cycle_length;
        w.phase_offset = off;
        if (p != w.phase) {
            w.phase = p;
            if (p == .bloom) w.pushEvent(0, .world_bloom, 0);
            if (p == .storm) w.pushEvent(0, .world_storm, 0);
        }
    }

    /// Flood the world with `count` fresh food items across living territories and the wild.
    pub fn floodFood(w: *World, count: usize) !void {
        const wild = bounds.inset(80);
        for (0..count) |k| {
            var pos: Vec2 = undefined;
            var food: FoodType = .universal;
            if (k % 4 < 3) {
                const si = k % society_count;
                pos = w.randomIn(w.territories[si].inset(16));
                food = if (w.rng().boolean()) societies[si].food else .universal;
            } else {
                pos = w.randomIn(wild);
                food = if (w.rng().boolean()) .universal else @fromBackingInt(@intCast(w.rng().intRangeLessThan(u8, 0, food_type_count)));
            }
            try w.resources.append(w.gpa, .{
                .pos = pos,
                .food = food,
                .amount = food_amount,
                .patch = null,
                .corpse = false,
            });
            w.field.deposit(scentChannel(food), pos.x, pos.y, 1.5);
        }
    }

    /// Drop a dense cluster of food around `pos` (e.g. at the camera center).
    pub fn dropFoodCluster(w: *World, pos: Vec2, food: FoodType, count: usize, spread: f32) !void {
        const safe = bounds.inset(20);
        for (0..count) |_| {
            const a = w.rng().float(f32) * std.math.tau;
            const d = @sqrt(w.rng().float(f32)) * spread;
            const p = Vec2{
                .x = std.math.clamp(pos.x + @cos(a) * d, safe.x, safe.x + safe.w),
                .y = std.math.clamp(pos.y + @sin(a) * d, safe.y, safe.y + safe.h),
            };
            try w.resources.append(w.gpa, .{
                .pos = p,
                .food = food,
                .amount = food_amount,
                .patch = null,
                .corpse = false,
            });
            w.field.deposit(scentChannel(food), p.x, p.y, 1.8);
        }
    }

    /// Remove all food and food scents from the world and halt regrowth (scarcity = .none).
    pub fn clearAllFood(w: *World) void {
        w.resources.clearRetainingCapacity();
        for (w.patches.items) |*p| {
            p.live = 0;
            p.timer = 0;
        }
        for (0..food_type_count) |t| {
            @memset(w.field.data[scentChannel(@fromBackingInt(@intCast(t)))], 0);
        }
        w.scarcity = .none;
    }

    /// Spawn a batch of fresh entities into a society's living territory.
    pub fn spawnRandomBatch(w: *World, society: u8, count: usize) !usize {
        var spawned: usize = 0;
        const area = w.territories[society].inset(28);
        for (0..count) |_| {
            const g = try gen.Genome.random(w.gpa, w.rng(), w.circuit.types);
            const e = try w.addEntity(society, w.randomIn(area), g);
            e.age = maturity_age + w.rng().float(f32) * 20;
            e.lineage = e.id;
            w.recordGeneration(e);
            spawned += 1;
        }
        return spawned;
    }

    pub fn spawnPrey(w: *World, count: usize) !void {
        const wild = bounds.inset(140);
        for (0..count) |_| {
            if (w.prey.items.len >= 12) break;
            try w.prey.append(w.gpa, .{
                .pos = w.randomIn(wild),
                .heading = w.rng().float(f32) * std.math.tau,
            });
        }
    }

    /// Give one mature pioneer per society a small insight boost in building & toolcraft
    /// so the user can compare organic discovery vs. cultural seeding.
    pub fn inspirePioneers(w: *World) void {
        for (0..society_count) |si| {
            for (w.entities.items) |*e| {
                if (e.dead != null or e.society != si or !e.mature()) continue;
                e.skills[@backingInt(Skill.building)] = @max(e.skills[@backingInt(Skill.building)], 0.45);
                e.skills[@backingInt(Skill.toolcraft)] = @max(e.skills[@backingInt(Skill.toolcraft)], 0.45);
                e.genome.cog.bias[gen.max_cog_hidden + @backingInt(gen.SocialAction.gather)] += 0.55;
                e.genome.cog.bias[gen.max_cog_hidden + @backingInt(gen.SocialAction.craft_tool)] += 0.55;
                e.genome.cog.bias[gen.max_cog_hidden + @backingInt(gen.SocialAction.build)] += 0.55;
                _ = e.genome.cog.sproutFromExperience(w.rng());
                break;
            }
        }
    }

    pub fn structureCount(w: *const World) u32 {
        var n: u32 = 0;
        for (w.structures.items) |s| if (s.integrity > 0 and s.complete()) {
            n += 1;
        };
        return n;
    }

    pub fn toolCount(w: *const World) u32 {
        var n: u32 = 0;
        for (w.entities.items) |e| if (e.dead == null and e.tool != .none) {
            n += 1;
        };
        return n;
    }

    pub fn preyCount(w: *const World) u32 {
        var n: u32 = 0;
        for (w.prey.items) |p| if (p.hp > 0) {
            n += 1;
        };
        return n;
    }

    pub fn predatorCount(w: *const World) u32 {
        var n: u32 = 0;
        for (w.predators.items) |p| if (p.hp > 0) {
            n += 1;
        };
        return n;
    }

    /// Spawn Apex Predators in the frontier (placed clear of society centers at spawn).
    pub fn spawnPredators(w: *World, count: usize) !void {
        const wild = bounds.inset(120);
        for (0..count) |_| {
            if (w.predators.items.len >= 6) break;
            var pos = w.randomIn(wild);
            var tries: usize = 0;
            while (tries < 12) : (tries += 1) {
                var safe = true;
                for (w.territories) |t| {
                    if (pos.dist(t.center()) < 260) {
                        safe = false;
                        break;
                    }
                }
                if (safe) break;
                pos = w.randomIn(wild);
            }
            try w.predators.append(w.gpa, .{
                .pos = pos,
                .heading = w.rng().float(f32) * std.math.tau,
            });
        }
    }

    /// Advance the simulation by one fixed tick.
    pub fn step(w: *World, dt: f32) !void {
        w.time += dt;
        w.raid_cooldown = @max(0, w.raid_cooldown - dt);
        w.field.update(dt);
        try w.updateFood(dt);
        if (!w.forage_only) {
            try w.updateMaterials(dt);
            try w.updatePrey(dt);
            try w.updatePredators(dt);
            w.updateStructures(dt);
        }

        w.brain_accum += dt;
        if (w.brain_accum >= 1 / brain_hz) {
            w.brain_accum -= 1 / brain_hz;
            w.removeDead();
            w.removeEaten();
            w.removeDepletedMaterials();
            w.removeDeadPrey();
            w.removeDeadPredators();
            w.removeCollapsedStructures();
            try w.rebuildGrid();
            w.think();
        }

        const n = w.entities.items.len;
        for (0..n) |i| {
            if (w.entities.items[i].dead == null) try w.act(i, dt);
        }
        w.ageContacts(dt);
        w.ageSignals(dt);
        try w.resolveCollisions();

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
            for (&row, 0..) |*r, s| r.* = @intCast(@min(w.population(s), std.math.maxInt(u16)));
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
        if (rate > 0) {
            const max_items: u16 = if (w.scarcity == .feast) patch_items * 2 else patch_items;
            for (w.patches.items, 0..) |*p, i| {
                if (p.budget <= 0) {
                    if (p.live == 0) w.relocate(p);
                    continue;
                }
                p.timer += dt * rate;
                if (p.timer >= 2.5) {
                    p.timer = 0;
                    if (p.live < max_items) try w.spawnFood(p, @intCast(i));
                }
            }
        }

        for (w.resources.items) |*r| {
            if (r.corpse) r.amount -= 1.2 * dt; // corpses rot
            if (r.amount > 0) w.field.deposit(scentChannel(r.food), r.pos.x, r.pos.y, r.amount / food_amount * 3.0 * dt);
        }
    }

    fn updateMaterials(w: *World, dt: f32) !void {
        w.material_timer += dt;
        if (w.material_timer >= 18) {
            w.material_timer = 0;
            if (w.materials.items.len < 54) {
                const kind: MaterialKind = if (w.rng().boolean()) .stone else .wood;
                const area = if (w.rng().float(f32) < 0.45)
                    w.territories[w.rng().uintLessThan(usize, society_count)].inset(25)
                else
                    bounds.inset(110);
                try w.materials.append(w.gpa, .{ .pos = w.randomIn(area), .kind = kind, .amount = 45 });
            }
        }
    }

    fn updatePrey(w: *World, dt: f32) !void {
        const edge = bounds.inset(45);
        for (w.prey.items) |*p| {
            if (p.hp <= 0) continue;
            p.flee_timer = @max(0, p.flee_timer - dt);
            p.stagger_timer = @max(0, p.stagger_timer - dt);
            if (p.flee_timer <= 0) {
                p.hp = @min(p.max_hp, p.hp + 1.5 * dt);
                p.heading += w.rng().floatNorm(f32) * 0.9 * dt;
            }
            const spd: f32 = if (p.stagger_timer > 0) 15 else if (p.flee_timer > 0) 42 else 18;
            p.pos.x += @cos(p.heading) * spd * dt;
            p.pos.y += @sin(p.heading) * spd * dt;
            if (!edge.contains(p.pos)) {
                p.pos.x = std.math.clamp(p.pos.x, edge.x, edge.x + edge.w);
                p.pos.y = std.math.clamp(p.pos.y, edge.y, edge.y + edge.h);
                p.heading += std.math.pi;
            }
        }
        w.prey_timer += dt;
        if (w.prey_timer >= 45) {
            w.prey_timer = 0;
            if (w.scarcity != .none and w.preyCount() < 5) try w.spawnPrey(1);
        }
    }

    fn updatePredators(w: *World, dt: f32) !void {
        const edge = bounds.inset(45);
        for (w.predators.items) |*p| {
            if (p.hp <= 0) continue;
            p.flee_timer = @max(0, p.flee_timer - dt);
            p.stagger_timer = @max(0, p.stagger_timer - dt);
            p.lunge_timer = @max(0, p.lunge_timer - dt);
            p.sated_timer = @max(0, p.sated_timer - dt);
            p.energy = @max(10, p.energy - 0.35 * dt);

            // Scan nearby entities: stalk isolated / vulnerable targets outside shelters,
            // but recoil and flee if outnumbered by 3+ spear-wielding defenders!
            var best_prey: ?usize = null;
            var best_score: f32 = 1e9;
            var spear_defenders: u32 = 0;
            var threat_cx: f32 = 0;
            var threat_cy: f32 = 0;
            const cc = cellCoords(p.pos);
            const x0: usize = cc[0] -| 3;
            const x1: usize = @min(grid_cols - 1, cc[0] + 3);
            const y0: usize = cc[1] -| 3;
            const y1: usize = @min(grid_rows - 1, cc[1] + 3);
            for (y0..y1 + 1) |gy| {
                for (x0..x1 + 1) |gx| {
                    var cur = w.grid_head[gy * grid_cols + gx];
                    while (cur >= 0) {
                        const ei: usize = @intCast(cur);
                        cur = w.grid_next.items[ei];
                        const e = &w.entities.items[ei];
                        if (e.dead != null) continue;
                        const d = p.pos.dist(e.pos);
                        if (d > 240) continue;
                        if (e.tool == .spear and d < 90) {
                            spear_defenders += 1;
                            threat_cx += e.pos.x;
                            threat_cy += e.pos.y;
                        }
                        if (e.in_shelter) continue; // completed shelters protect beings inside!
                        // Prefer isolated, young, or weakened stragglers.
                        const vuln: f32 = if (!e.mature()) 0.65 else if (e.energy < 55) 0.75 else 1.0;
                        const crowd_pen: f32 = 1.0 + @as(f32, @floatFromInt(@min(e.allies_near, 6))) * 0.25;
                        const score = d * vuln * crowd_pen;
                        if (score < best_score) {
                            best_score = score;
                            best_prey = ei;
                        }
                    }
                }
            }

            if (spear_defenders >= 3 or p.hp < 45) {
                if (spear_defenders > 0) {
                    const avg = Vec2{ .x = threat_cx / @as(f32, @floatFromInt(spear_defenders)), .y = threat_cy / @as(f32, @floatFromInt(spear_defenders)) };
                    p.heading = std.math.atan2(p.pos.y - avg.y, p.pos.x - avg.x);
                }
                p.flee_timer = @max(p.flee_timer, 3.0);
            }

            var spd: f32 = 24;
            if (p.flee_timer > 0) {
                spd = if (p.stagger_timer > 0) 20 else 50;
            } else if (p.sated_timer <= 0 and best_prey != null) {
                const ti = best_prey.?;
                const target_e = &w.entities.items[ti];
                const d = p.pos.dist(target_e.pos);
                p.heading += steerTo(p.heading, p.pos, target_e.pos, 4.2) * dt;
                if (d < 85 and p.lunge_timer <= 0) p.lunge_timer = 1.2;
                spd = if (p.stagger_timer > 0) 18 else if (p.lunge_timer > 0) 54 else 38;

                // Strike prey if within bite reach.
                if (d < p.radius() + target_e.radius() + 6 and target_e.dead == null) {
                    const dmg = 28 * (1 - 0.25 * target_e.skill(.combat)) * dt;
                    target_e.energy -= dmg;
                    target_e.resting = false;
                    target_e.remember(.danger, p.pos, 1.0);
                    target_e.genome.cog.learn(-dmg * 0.16);
                    target_e.genome.cog.noradrenaline = 1.0;
                    if (target_e.call_cooldown <= 0) w.emitSignal(ti, .danger_call, p.pos);
                    w.field.deposit(alarmChannel(target_e.society), target_e.pos.x, target_e.pos.y, dmg * 0.9);
                    if (target_e.energy <= 0 and target_e.dead == null) {
                        p.kills += 1;
                        p.sated_timer = 22; // digest kill before stalking again
                        p.energy = @min(140, p.energy + 45);
                        p.hp = @min(p.max_hp, p.hp + 25);
                        try w.killCorpse(ti, .killed, 18);
                    }
                }
            } else {
                p.hp = @min(p.max_hp, p.hp + 1.0 * dt);
                p.heading += w.rng().floatNorm(f32) * 0.8 * dt;
            }

            p.pos.x += @cos(p.heading) * spd * dt;
            p.pos.y += @sin(p.heading) * spd * dt;
            if (!edge.contains(p.pos)) {
                p.pos.x = std.math.clamp(p.pos.x, edge.x, edge.x + edge.w);
                p.pos.y = std.math.clamp(p.pos.y, edge.y, edge.y + edge.h);
                p.heading += std.math.pi;
            }
        }
        w.predator_timer += dt;
        if (w.predator_timer >= 120) {
            w.predator_timer = 0;
            if (w.scarcity != .none and w.predatorCount() < 2) try w.spawnPredators(1);
        }
    }

    fn removeDeadPredators(w: *World) void {
        var i: usize = 0;
        while (i < w.predators.items.len) {
            if (w.predators.items[i].hp <= 0) {
                _ = w.predators.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn updateStructures(w: *World, dt: f32) void {
        const storm_wear: f32 = if (w.phase == .storm) 0.10 else 0.035;
        for (w.structures.items) |*s| {
            if (s.complete()) {
                s.integrity -= storm_wear * dt;
            } else {
                // Unfinished piles slowly erode if abandoned.
                s.progress -= 0.15 * dt;
                if (s.progress <= 0) s.integrity = 0;
            }
        }
    }

    fn removeDepletedMaterials(w: *World) void {
        var i: usize = 0;
        while (i < w.materials.items.len) {
            if (w.materials.items[i].amount <= 0) {
                _ = w.materials.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn removeDeadPrey(w: *World) void {
        var i: usize = 0;
        while (i < w.prey.items.len) {
            if (w.prey.items[i].hp <= 0) {
                _ = w.prey.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn removeCollapsedStructures(w: *World) void {
        var i: usize = 0;
        while (i < w.structures.items.len) {
            if (w.structures.items[i].integrity <= 0) {
                _ = w.structures.swapRemove(i);
                continue;
            }
            i += 1;
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

    fn cellCoords(pos: Vec2) [2]usize {
        const cx: usize = @intFromFloat(std.math.clamp((pos.x - bounds.x) / grid_cell, 0, @as(f32, @floatFromInt(grid_cols - 1))));
        const cy: usize = @intFromFloat(std.math.clamp((pos.y - bounds.y) / grid_cell, 0, @as(f32, @floatFromInt(grid_rows - 1))));
        return .{ cx, cy };
    }

    fn rebuildGrid(w: *World) !void {
        @memset(&w.grid_head, -1);
        const n = w.entities.items.len;
        try w.grid_next.resize(w.gpa, n);
        for (w.entities.items, 0..) |e, idx| {
            if (e.dead != null) {
                w.grid_next.items[idx] = -1;
                continue;
            }
            const cc = cellCoords(e.pos);
            const cell = cc[1] * grid_cols + cc[0];
            w.grid_next.items[idx] = w.grid_head[cell];
            w.grid_head[cell] = @intCast(idx);
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
        e.cannibal_target = false;
        e.enemies_near = 0;
        e.allies_near = 0;
        var close_allies: u32 = 0;
        e.enemy_dist = sense_range;
        e.ally_dist = sense_range;
        var mate_dist: f32 = sense_range;
        var weak_kin: ?u32 = null;
        var weak_kin_dist: f32 = sense_range;
        const ready = e.readyToMate();
        const cc = cellCoords(e.pos);
        const x0: usize = cc[0] -| 2;
        const x1: usize = @min(grid_cols - 1, cc[0] + 2);
        const y0: usize = cc[1] -| 2;
        const y1: usize = @min(grid_rows - 1, cc[1] + 2);
        for (y0..y1 + 1) |gy| {
            for (x0..x1 + 1) |gx| {
                var cur = w.grid_head[gy * grid_cols + gx];
                while (cur >= 0) {
                    const oi: usize = @intCast(cur);
                    cur = w.grid_next.items[oi];
                    const o = &w.entities.items[oi];
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
                        if (o.energy <= e.energy + 12 and o.energy < 70 and d < weak_kin_dist) {
                            weak_kin_dist = d;
                            weak_kin = @intCast(oi);
                        }
                    }
                    if (ready and o.readyToMate() and d < mate_dist) {
                        mate_dist = d;
                        e.mate = @intCast(oi);
                    }
                }
            }
        }
        e.huddled = close_allies >= 2;
        // Emergent starvation cannibalism: desperate meat-capable predators with no food
        // in sight or smell can turn on weaker kin as a last-resort survival strategy.
        if (!w.forage_only and e.enemy == null and weak_kin != null and
            e.energy < 36 and e.since_meal > 18 and e.visible_food == null and e.odour < 0.08 and
            canEat(e, .meat) > 0 and e.genome.trait(.aggression) > 0.58)
        {
            e.enemy = weak_kin;
            e.enemy_dist = weak_kin_dist;
            e.cannibal_target = true;
        }

        // Materials, structures (friendly & enemy), wild prey, and apex predators.
        e.near_material = null;
        e.near_structure = null;
        e.near_cache = null;
        e.enemy_structure = null;
        e.near_prey = null;
        e.near_predator = null;
        e.predator_dist = sense_range;
        e.in_shelter = false;
        e.intruder_in_home = false;
        if (!w.forage_only) {
            const my_home = w.territories[e.society];
            if (e.enemy) |ei| {
                if (my_home.contains(w.entities.items[ei].pos)) e.intruder_in_home = true;
            }
            var mat_dist: f32 = sense_range;
            for (w.materials.items, 0..) |m_item, mi| {
                if (m_item.amount <= 0) continue;
                const d = m_item.pos.dist(e.pos);
                if (d < mat_dist) {
                    mat_dist = d;
                    e.near_material = @intCast(mi);
                }
            }
            var str_dist: f32 = sense_range * 1.4;
            var cache_dist: f32 = sense_range * 1.25;
            var estr_dist: f32 = sense_range;
            for (w.structures.items, 0..) |st, si| {
                if (st.integrity <= 0) continue;
                const d = st.pos.dist(e.pos);
                if (st.society != e.society) {
                    if (st.complete() and d < estr_dist) {
                        estr_dist = d;
                        e.enemy_structure = @intCast(si);
                    }
                    continue;
                }
                if (st.complete() and st.kind == .shelter and d < st.radius()) {
                    e.in_shelter = true;
                }
                if (st.complete() and st.kind == .cache and d < cache_dist) {
                    cache_dist = d;
                    e.near_cache = @intCast(si);
                }
                // Prefer incomplete/damaged structures for building, or completed shelters during storms.
                const useful_struct = !st.complete() or st.integrity < 85 or (w.phase == .storm and st.kind == .shelter);
                if (useful_struct and d < str_dist) {
                    str_dist = d;
                    e.near_structure = @intCast(si);
                }
            }
            var prey_dist: f32 = sense_range * 1.15;
            for (w.prey.items, 0..) |pr, pi| {
                if (pr.hp <= 0) continue;
                const d = pr.pos.dist(e.pos);
                if (d < prey_dist) {
                    prey_dist = d;
                    e.near_prey = @intCast(pi);
                }
            }
            var pred_dist: f32 = sense_range * 1.25;
            for (w.predators.items, 0..) |pd, pi| {
                if (pd.hp <= 0) continue;
                const d = pd.pos.dist(e.pos);
                if (d < pred_dist) {
                    pred_dist = d;
                    e.near_predator = @intCast(pi);
                    e.predator_dist = @min(d, sense_range);
                }
                if (d < sense_range * 1.4 and my_home.contains(pd.pos)) {
                    e.intruder_in_home = true;
                }
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
        e.bump_cooldown = @max(0, e.bump_cooldown - dt);
        e.craft_cooldown = @max(0, e.craft_cooldown - dt);

        // Age episodic memories & update internal neuromodulators (arousal, calm, motivation).
        if (!w.forage_only) {
            for (&e.memories) |*mem| {
                if (mem.confidence <= 0) continue;
                mem.age += dt;
                mem.confidence = @max(0, mem.confidence - 0.0025 * dt);
            }
            const threat_arousal: f32 = if (e.near_predator != null or e.enemies_near > 0 or e.alarm > 0.2 or e.heard_kind == .danger_call) 0.92 else if (w.phase == .storm and !e.in_shelter) 0.55 else 0.15;
            g.cog.noradrenaline = std.math.clamp(g.cog.noradrenaline + (threat_arousal - g.cog.noradrenaline) * @min(1, dt * 1.4), 0.05, 1.0);
            const calm_target: f32 = if (e.energy > 80 and (e.in_shelter or e.allies_near > 0) and e.enemies_near == 0 and e.near_predator == null) 0.85 else if (e.energy < 40 or e.enemies_near > 0 or e.near_predator != null) 0.15 else 0.5;
            g.cog.serotonin = std.math.clamp(g.cog.serotonin + (calm_target - g.cog.serotonin) * @min(1, dt * 0.6), 0.05, 1.0);
            g.cog.dopamine = std.math.clamp(g.cog.dopamine + (0.5 - g.cog.dopamine) * @min(1, dt * 0.25), 0.05, 1.0);
        }

        // Social decision (26 egocentric/sensory/memory inputs -> leaky recurrent hidden state -> 8 actions + 3 continuous motor/mod outputs).
        // Thinking tempo adapts dynamically: alert/aroused entities deliberate faster in crisis!
        const home_rect = w.territories[e.society];
        e.action_timer -= dt;
        if (e.action_timer <= 0 and !w.forage_only) {
            e.action_timer = 0.55 - 0.30 * g.cog.noradrenaline;
            const env_sig: f32 = if (w.phase == .storm and !e.in_shelter)
                1.0
            else if (e.in_shelter)
                -0.5
            else if (e.near_prey != null)
                0.7
            else
                0;
            const mem_pos_conf: f32 = blk: {
                var best: f32 = 0;
                for (e.memories) |mem| {
                    if ((mem.kind == .food or mem.kind == .material or mem.kind == .shelter) and mem.confidence > best) {
                        best = mem.confidence;
                    }
                }
                break :blk best;
            };
            var mem_social_cue: f32 = 0;
            if (e.ally) |ai| mem_social_cue += e.trustOf(w.entities.items[ai].id);
            if (e.enemy) |ei| mem_social_cue += e.trustOf(w.entities.items[ei].id);
            if (e.recall(.danger, 0.3)) |di| {
                if (e.pos.dist(e.memories[di].pos) < 110) mem_social_cue -= e.memories[di].confidence;
            }
            mem_social_cue = std.math.clamp(mem_social_cue, -1, 1);

            // Egocentric directional vision (-1 left .. 0 ahead .. +1 right).
            const dir_food: f32 = if (e.visible_food) |fp|
                egocentricBearing(e.heading, e.pos, fp)
            else if (e.near_cache) |ci|
                (if (w.structures.items[ci].stored_food > 5) egocentricBearing(e.heading, e.pos, w.structures.items[ci].pos) else 0)
            else if (e.recall(.food, 0.2)) |fi|
                egocentricBearing(e.heading, e.pos, e.memories[fi].pos)
            else
                0;

            const dir_threat: f32 = if (e.near_predator) |pi|
                egocentricBearing(e.heading, e.pos, w.predators.items[pi].pos)
            else if (e.enemy) |ei|
                egocentricBearing(e.heading, e.pos, w.entities.items[ei].pos)
            else if (e.recall(.danger, 0.3)) |di|
                egocentricBearing(e.heading, e.pos, e.memories[di].pos)
            else
                0;

            const dir_kin: f32 = if (e.ally) |ai|
                egocentricBearing(e.heading, e.pos, w.entities.items[ai].pos)
            else if (e.heard_kind != null)
                egocentricBearing(e.heading, e.pos, e.heard_pos)
            else
                0;

            const dir_material: f32 = if (e.near_material) |mi|
                egocentricBearing(e.heading, e.pos, w.materials.items[mi].pos)
            else if (e.recall(.material, 0.2)) |qi|
                egocentricBearing(e.heading, e.pos, e.memories[qi].pos)
            else
                0;

            const dir_structure: f32 = if (e.near_structure) |si|
                egocentricBearing(e.heading, e.pos, w.structures.items[si].pos)
            else if (e.enemy_structure) |esi|
                egocentricBearing(e.heading, e.pos, w.structures.items[esi].pos)
            else if (e.recall(.shelter, 0.25)) |shi|
                egocentricBearing(e.heading, e.pos, e.memories[shi].pos)
            else
                0;

            const dir_home: f32 = egocentricBearing(e.heading, e.pos, home_rect.center());

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
                if (e.carrying != .none) 1 else 0,
                if (e.tool != .none) 1 else 0,
                if (e.near_material != null) 1 else 0,
                env_sig,
                mem_pos_conf,
                mem_social_cue,
                if (e.near_predator != null) 1 - e.predator_dist / sense_range else 0,
                if (e.intruder_in_home) 1 else 0,
                dir_food,
                dir_threat,
                dir_kin,
                dir_material,
                dir_structure,
                dir_home,
            });
        }

        // Physical developmental constraint only: infants cannot fight, craft, build, or mate.
        // All adult/juvenile action choices come directly from the recurrent CognitiveBrain (no forced overrides!).
        const lstage = e.stage();
        const hunger = std.math.clamp((80 - e.energy) / 60, 0, 1);
        if (lstage == .infant and (e.action == .fight or e.action == .craft_tool or e.action == .build or e.action == .mate)) {
            e.action = .forage;
        }
        const hunting_prey = !w.forage_only and lstage != .infant and e.near_prey != null and e.near_predator == null and e.enemy == null and
            (e.action == .fight or (e.tool == .spear and e.action == .forage and e.visible_food == null and e.energy < 95));

        // Steering blends the FlyWire brainstem with continuous cortical steering (g.cog.turn_out).
        // A slow baseline is subtracted to cancel the connectome's built-in left/right bias.
        const m = e.motor;
        const turn_diff = m.turn_R - m.turn_L;
        e.turn_base += (turn_diff - e.turn_base) * @min(1, dt / 1.5);
        var turn = std.math.clamp(g.motorGene(.turn) * (turn_diff - e.turn_base), -6, 6) + g.motorGene(.wander) * w.rng().floatNorm(f32);
        if (!w.forage_only) turn += g.cog.turn_out * 3.5;
        const target: ?Vec2 = if (hunting_prey)
            w.prey.items[e.near_prey.?].pos
        else switch (e.action) {
            .forage => null,
            .fight => if (e.near_predator) |pi| w.predators.items[pi].pos else if (e.enemy) |o| w.entities.items[o].pos else if (e.enemy_structure) |si| w.structures.items[si].pos else null,
            .mate => if (e.mate) |o| w.entities.items[o].pos else null,
            .socialize => if (e.ally) |o| (if (e.ally_dist > 30 + 60 * g.trait(.sociability)) w.entities.items[o].pos else null) else null,
            .flee => if (e.near_predator) |pi| away(e.pos, w.predators.items[pi].pos) else if (e.enemy) |o| away(e.pos, w.entities.items[o].pos) else null,
            .gather => if (e.carrying == .none) (if (e.near_material) |mi| w.materials.items[mi].pos else null) else (if (e.near_structure) |si| w.structures.items[si].pos else null),
            .craft_tool => if (e.carrying == .none) (if (e.near_material) |mi| w.materials.items[mi].pos else null) else null,
            .build => if (e.carrying == .none) (if (e.near_material) |mi| w.materials.items[mi].pos else null) else (if (e.near_structure) |si| w.structures.items[si].pos else if (!w.territories[e.society].contains(e.pos)) w.territories[e.society].center() else null),
        };
        if (target) |t| turn = steerTo(e.heading, e.pos, t, 4.8) + (if (!w.forage_only) g.cog.turn_out * 1.2 else 0);

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

        // Storm comfort/exposure signal feeds directly into ABCD Hebbian learning instead of hardcoding storm steering.
        var seeking_shelter = false;
        if (!w.forage_only and w.phase == .storm) {
            if (e.in_shelter or e.huddled) {
                g.cog.learn(0.03 * dt);
            } else {
                g.cog.learn(-0.04 * dt);
            }
        }

        // Hungry entities with no food in sight can steer toward a stocked society Food Cache.
        var seeking_cache = false;
        if (!w.forage_only and !acted_on_signal and !seeking_shelter and target == null and e.action == .forage and e.visible_food == null and e.energy < 60) {
            if (e.near_cache) |ci| {
                const cache = w.structures.items[ci];
                if (cache.stored_food > 5) {
                    turn = steerTo(e.heading, e.pos, cache.pos, 4.0);
                    e.explore_target = null;
                    seeking_cache = true;
                }
            }
        }

        // Episodic Spatial Memory Recall & Belief Updating: navigate by mental map when nothing is locally visible.
        e.recalling = null;
        if (!w.forage_only and !acted_on_signal and !seeking_shelter and !seeking_cache and target == null) {
            // 1. Storm shelter recall (even from far across the world).
            if (w.phase == .storm and !e.in_shelter and e.energy > 48 and e.action != .fight and e.action != .flee) {
                if (e.recall(.shelter, 0.25)) |mi| {
                    const mpos = e.memories[mi].pos;
                    if (e.pos.dist(mpos) > 28) {
                        turn = steerTo(e.heading, e.pos, mpos, 3.9);
                        e.recalling = .shelter;
                        seeking_shelter = true;
                    } else if (!e.in_shelter) {
                        // Shelter collapsed or gone: update belief!
                        e.memories[mi].confidence = 0;
                    }
                }
            }
            // 2. Remembered danger zone avoidance (for non-aggressive or injured individuals).
            if (e.recalling == null and (g.trait(.aggression) < 0.58 or e.energy < 65) and e.action != .fight) {
                if (e.recall(.danger, 0.30)) |di| {
                    if (e.pos.dist(e.memories[di].pos) < 95) {
                        turn = steerTo(e.heading, e.pos, away(e.pos, e.memories[di].pos), 3.8);
                        e.recalling = .danger;
                        g.cog.noradrenaline = @min(1, g.cog.noradrenaline + 0.15 * dt);
                    }
                }
            }
            // 3. Food patch memory recall when hungry with no local food/scent.
            if (e.recalling == null and e.action == .forage and e.visible_food == null and e.odour < 0.14 and e.energy < 72) {
                if (e.recall(.food, 0.20)) |fi| {
                    const mpos = e.memories[fi].pos;
                    if (e.pos.dist(mpos) < 26) {
                        // Arrived and patch is gone -> belief update + mild negative TD surprise!
                        e.memories[fi].confidence = 0;
                        g.cog.learn(-0.18);
                    } else {
                        turn = steerTo(e.heading, e.pos, mpos, 3.8);
                        e.explore_target = null;
                        e.recalling = .food;
                    }
                }
            }
            // 4. Quarry / material recall when wanting to gather, craft, or build.
            if (e.recalling == null and e.carrying == .none and e.near_material == null and (e.action == .gather or e.action == .craft_tool or e.action == .build)) {
                if (e.recall(.material, 0.20)) |qi| {
                    const mpos = e.memories[qi].pos;
                    if (e.pos.dist(mpos) < 28) {
                        e.memories[qi].confidence = 0;
                    } else {
                        turn = steerTo(e.heading, e.pos, mpos, 3.7);
                        e.recalling = .material;
                    }
                }
            }
            // 5. Hunting ground recall for spear-wielding hunters.
            if (e.recalling == null and e.tool == .spear and e.near_prey == null and e.energy > 45 and e.energy < 105 and e.action != .flee) {
                if (e.recall(.prey, 0.25)) |pi| {
                    const mpos = e.memories[pi].pos;
                    if (e.pos.dist(mpos) < 35) {
                        e.memories[pi].confidence = 0;
                    } else {
                        turn = steerTo(e.heading, e.pos, mpos, 3.6);
                        e.recalling = .prey;
                    }
                }
            }
        }

        if (!w.forage_only and !acted_on_signal and !seeking_shelter and !seeking_cache and e.recalling == null and target == null and e.action == .forage) {
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

        if (e.explore_target == null and !seeking_shelter and !seeking_cache and e.recalling == null and !acted_on_signal and e.visible_food == null and target == null) {
            const stage_roam: f32 = if (lstage == .infant) 0.3 else if (lstage == .juvenile) 0.65 else 1.0;
            const roam = (160 + 600 * (1 - g.trait(.territoriality)) + 500 * hunger) * stage_roam;
            const home = home_rect.inset(-roam);
            if (!home.contains(e.pos)) turn = steerTo(e.heading, e.pos, home_rect.center(), 2.5);
        }

        // Resting / sleep state: tired, non-starving beings pause to recover fatigue and save energy.
        if (!w.forage_only) {
            const danger_near = e.enemies_near > 0 or e.heard_kind == .danger_call or e.action == .fight or e.action == .flee or hunting_prey;
            if (e.resting) {
                if (e.fatigue <= 0.12 or e.energy < 38 or danger_near) e.resting = false;
            } else if (!danger_near and !e.feeding and e.energy > 48) {
                const rest_thresh: f32 = if (e.in_shelter) 0.40 else if (w.phase == .storm and e.huddled) 0.45 else if (e.energy > 95 and e.since_meal < 15) 0.65 else 0.85;
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
        if (e.action == .flee and (e.enemy != null or e.near_predator != null)) speed = base * 1.2;
        if (hunting_prey or (e.action == .fight and (e.enemy != null or e.near_predator != null))) speed = @max(speed, base * 1.12);
        if ((e.explore_target != null and e.odour < 0.25) or e.visible_food != null or seeking_shelter or seeking_cache or e.recalling != null or acted_on_signal or target != null) {
            speed = @max(speed, base * (if (e.energy < 55) @as(f32, 1.05) else 0.95));
        }
        if (!w.forage_only) speed *= std.math.clamp(1.0 + 0.30 * g.cog.speed_out, 0.55, 1.35);
        if (e.carrying != .none) speed *= 0.88;
        speed *= switch (lstage) {
            .infant => 0.72,
            .juvenile => 0.92,
            .adult => 1.0,
            .elder => 0.88,
        };
        if (w.phase == .storm and e.in_shelter and !e.feeding and e.energy > 50 and e.action != .fight and e.action != .flee) {
            speed *= 0.12;
        } else if (w.phase == .storm and e.huddled and !e.feeding and e.energy > 50) {
            speed *= 0.45;
        }
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
                    const basket_mult: f32 = if (e.tool == .basket) 1.35 else 1.0;
                    const bite = @min(r.amount, 30 * (1 + 0.35 * fskill) * basket_mult * m.feed * dt);
                    r.amount -= bite;
                    const gained = bite * value * (1 + 0.25 * fskill);
                    e.energy = @min(max_energy, e.energy + gained);
                    e.food_eaten += gained;
                    e.since_meal = 0;
                    e.addSkill(.foraging, bite * 0.004);
                    if (e.tool == .basket) {
                        e.tool_durability -= 1.5 * dt;
                        if (e.tool_durability <= 0) e.tool = .none;
                    }
                    e.genome.cog.learn(gained * 0.06);
                    if (!w.forage_only and r.amount > 6) e.remember(.food, r.pos, 0.75);
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
        // Physical crosswind during storms (completed shelters block 90%, huddled kin block 80%).
        const wind_scale: f32 = if (w.phase == .storm and !w.forage_only)
            (if (e.in_shelter) @as(f32, 0.1) else if (e.huddled or e.resting) @as(f32, 0.2) else if (home_rect.contains(e.pos)) @as(f32, 0.5) else 1.0)
        else
            0;
        const step_x = (@cos(e.heading) * speed + e.bump_vel.x + 14 * wind_scale) * dt;
        const step_y = (@sin(e.heading) * speed + e.bump_vel.y + 4.5 * wind_scale) * dt;
        e.pos.x += step_x;
        e.pos.y += step_y;
        const moved = @sqrt(step_x * step_x + step_y * step_y);
        e.distance_traveled += moved;
        if (e.resting) {
            const rest_rate: f32 = if (e.in_shelter) 0.19 else 0.11;
            e.fatigue = @max(0, e.fatigue - rest_rate * dt);
        } else {
            const fatigue_gain = (0.008 + 0.0005 * @abs(speed)) * (1 - 0.35 * g.trait(.efficiency));
            e.fatigue = @min(1, e.fatigue + fatigue_gain * dt);
        }
        if (e.in_shelter and !w.forage_only) {
            e.addSkill(.building, 0.002 * dt);
            e.remember(.shelter, e.pos, 0.8);
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

        // Metabolism, harsher in hard environments and during world storms; shelters, resting & huddling conserve energy.
        // Larger cognitive brains also carry a small real metabolic upkeep so only useful growth survives selection.
        const shelter_mult: f32 = if (e.in_shelter) 0.35 else if (w.phase == .storm and e.huddled) 0.55 else 1.0;
        const rest_mult: f32 = if (e.resting) 0.45 else 1.0;
        const harsh = (if (home_rect.contains(e.pos)) soc.harshness else 0.3) * w.phase.harshness() * shelter_mult;
        const move_cost = 0.01 * (1 - 0.35 * e.skill(.navigation)) * @abs(speed);
        const carry_cost: f32 = if (e.carrying != .none) 0.12 else 0;
        const brain_cost = 0.004 * @as(f32, @floatFromInt(g.cog.hidden_count)) + 0.0003 * @as(f32, @floatFromInt(g.cog.activeSynapses()));
        const stage_drain: f32 = switch (lstage) {
            .infant => 0.65,
            .juvenile => 0.85,
            .adult => 1.0,
            .elder => 0.92,
        };
        const drain = (0.5 + 0.6 * g.trait(.speed) - 0.4 * g.trait(.efficiency) + move_cost + carry_cost + brain_cost) * (1 + 0.5 * harsh) * rest_mult * stage_drain;
        e.energy -= drain * dt;
        if (e.energy < 25) e.genome.cog.learn(-0.08 * dt);

        // Emergent material gathering, tool-crafting, stigmergic building, cache use, and wild prey hunting.
        if (!w.forage_only and e.dead == null) {
            // 1. Pick up raw material (wood/stone) when gathering, crafting, or building.
            if (e.carrying == .none and (e.action == .gather or e.action == .craft_tool or e.action == .build)) {
                if (e.near_material) |mi| {
                    const mat = &w.materials.items[mi];
                    if (mat.amount > 0 and mat.pos.dist(e.pos) < e.radius() + 14) {
                        mat.amount -= 15;
                        e.carrying = if (mat.kind == .wood) .wood else .stone;
                        if (mat.amount > 0) e.remember(.material, mat.pos, 0.72);
                        e.genome.cog.learn(0.25);
                    }
                }
            }
            if (e.near_prey) |pi| {
                const pr = w.prey.items[pi];
                if (pr.hp > 0) e.remember(.prey, pr.pos, 0.55);
            }

            // 2. Craft a tool from carried material (stone -> Spear, wood -> Basket).
            const want_craft = e.carrying != .none and e.craft_cooldown <= 0 and e.energy > 45 and
                (e.action == .craft_tool or (e.action == .gather and e.carrying == .stone and e.tool == .none));
            if (want_craft) {
                e.craft_cooldown = 4.0;
                e.energy -= 2.5;
                const chance = 0.35 + 0.65 * e.skill(.toolcraft);
                if (w.rng().float(f32) < chance) {
                    e.tool = if (e.carrying == .stone) .spear else .basket;
                    e.tool_durability = 100;
                    e.carrying = .none;
                    e.addSkill(.toolcraft, 0.28);
                    e.genome.cog.learn(0.95);
                    _ = e.genome.cog.sproutFromExperience(w.rng());
                    const st = &w.stats[e.society];
                    st.tools_crafted += 1;
                    if (!st.discovered_tools) {
                        st.discovered_tools = true;
                        w.pushEvent(e.society, .tool_discovered, st.tools_crafted);
                    }
                } else {
                    // Trial-and-error learning: failed attempts still build toolcraft intuition.
                    e.addSkill(.toolcraft, 0.10);
                    e.genome.cog.learn(0.15);
                }
            }

            // 3. Stigmergic building & repair: contribute carried wood/stone to a structure or start a foundation.
            const want_build = e.carrying != .none and e.energy > 42 and
                (e.action == .build or (e.action == .gather and (e.carrying == .wood or e.tool != .none)));
            if (want_build) {
                try w.tryBuild(i);
            }

            // 4. Food Cache storage (deposit surplus when well-fed, withdraw when hungry).
            if (e.near_cache) |ci| {
                const cache = &w.structures.items[ci];
                if (cache.complete() and cache.pos.dist(e.pos) < cache.radius() + 10) {
                    if (e.energy > 96 and cache.stored_food < max_cache_food - 10 and e.craft_cooldown <= 0) {
                        const add: f32 = if (e.tool == .basket) 32 else 22;
                        cache.stored_food = @min(max_cache_food, cache.stored_food + add);
                        e.energy -= 12;
                        e.craft_cooldown = 3.5;
                        e.addSkill(.care, 0.08);
                        e.genome.cog.learn(0.5);
                    } else if (e.energy < 62 and cache.stored_food > 0) {
                        const take = @min(cache.stored_food, 28 * dt);
                        cache.stored_food -= take;
                        e.energy = @min(max_energy, e.energy + take);
                        e.food_eaten += take;
                        e.since_meal = 0;
                        e.feeding = true;
                        e.genome.cog.learn(0.4 * dt);
                    }
                }
            }

            // 5. Wild Prey hunting (Spears grant long safe reach, high damage, stagger, and bigger harvest!).
            if (hunting_prey) {
                if (e.near_prey) |pi| {
                    const pr = &w.prey.items[pi];
                    const has_spear = e.tool == .spear;
                    const hreach = e.radius() + 14 + (if (has_spear) @as(f32, 12) else 0);
                    if (pr.hp > 0 and pr.pos.dist(e.pos) < hreach) {
                        const tskill = e.skill(.toolcraft);
                        const dmg = if (has_spear)
                            (22 + 26 * g.trait(.aggression)) * (1 + 0.5 * tskill + 0.3 * e.skill(.combat)) * dt
                        else
                            (8 + 14 * g.trait(.aggression)) * (1 + 0.25 * e.skill(.combat)) * dt;
                        pr.hp -= dmg;
                        pr.flee_timer = 3.0;
                        pr.heading = std.math.atan2(pr.pos.y - e.pos.y, pr.pos.x - e.pos.x);
                        e.energy -= 2.5 * dt;
                        if (has_spear) {
                            pr.stagger_timer = 1.6;
                            e.addSkill(.toolcraft, 0.06 * dt);
                            e.tool_durability -= 4.0 * dt;
                            if (e.tool_durability <= 0) e.tool = .none;
                        } else {
                            // Unarmed hunter takes counter-kick damage from wild quarry.
                            e.energy -= 6.5 * dt;
                            e.addSkill(.combat, 0.04 * dt);
                        }
                        if (e.call_cooldown <= 0 and has_spear) w.emitSignal(i, .food_found, pr.pos);
                        if (pr.hp <= 0) {
                            e.kills += 1;
                            e.addSkill(.toolcraft, 0.16);
                            e.addSkill(.combat, 0.08);
                            e.genome.cog.learn(1.2);
                            _ = e.genome.cog.sproutFromExperience(w.rng());
                            w.stats[e.society].prey_hunted += 1;
                            // Rich harvest: universal + meat piles so any society benefits from hunting!
                            const meat_amt: f32 = if (has_spear) 60 else 42;
                            try w.resources.append(w.gpa, .{ .pos = pr.pos, .food = .meat, .amount = meat_amt, .patch = null, .corpse = false });
                            try w.resources.append(w.gpa, .{ .pos = .{ .x = pr.pos.x + 8, .y = pr.pos.y - 6 }, .food = .universal, .amount = 36, .patch = null, .corpse = false });
                            try w.resources.append(w.gpa, .{ .pos = .{ .x = pr.pos.x - 8, .y = pr.pos.y + 6 }, .food = .universal, .amount = 36, .patch = null, .corpse = false });
                            w.field.deposit(scentChannel(.universal), pr.pos.x, pr.pos.y, 3.0);
                            w.field.deposit(scentChannel(.meat), pr.pos.x, pr.pos.y, 3.0);
                        }
                    }
                }
            }
            // 6. Cross-society Food Cache raiding & structure sieging (real territorial stakes!).
            if (e.enemy_structure) |esi| {
                const est = &w.structures.items[esi];
                if (est.complete() and est.integrity > 0 and est.pos.dist(e.pos) < est.radius() + 12) {
                    if (est.kind == .cache and est.stored_food > 0 and e.energy < 110) {
                        const stolen = @min(est.stored_food, 22 * dt);
                        est.stored_food -= stolen;
                        e.energy = @min(max_energy, e.energy + stolen);
                        e.food_eaten += stolen;
                        e.since_meal = 0;
                        e.feeding = true;
                        e.genome.cog.learn(0.55 * dt);
                        w.field.deposit(alarmChannel(est.society), est.pos.x, est.pos.y, 4.0 * dt);
                        if (w.raid_cooldown <= 0) {
                            w.raid_cooldown = 45;
                            w.stats[est.society].raids_suffered += 1;
                            w.pushEvent(est.society, .cache_raided, e.society);
                        }
                    } else if (e.action == .fight) {
                        const siege = (10 + 16 * g.trait(.aggression)) * (if (e.tool == .spear) @as(f32, 1.6) else 1.0) * dt;
                        est.integrity -= siege;
                        e.energy -= 2.5 * dt;
                        w.field.deposit(alarmChannel(est.society), est.pos.x, est.pos.y, 3.0 * dt);
                    }
                }
            }

            // 7. Defending against Apex Predators (spears give safe reach, stagger, and trophy feast!).
            if (e.action == .fight) {
                if (e.near_predator) |pdi| {
                    const pd = &w.predators.items[pdi];
                    const has_spear = e.tool == .spear;
                    const preach = e.radius() + pd.radius() + (if (has_spear) @as(f32, 14) else 5);
                    if (pd.hp > 0 and pd.pos.dist(e.pos) < preach) {
                        const atk = if (has_spear)
                            (24 + 28 * g.trait(.aggression)) * (1 + 0.5 * e.skill(.toolcraft) + 0.35 * e.skill(.combat)) * dt
                        else
                            (8 + 14 * g.trait(.aggression)) * (1 + 0.25 * e.skill(.combat)) * dt;
                        pd.hp -= atk;
                        e.energy -= 3.0 * dt;
                        e.addSkill(.combat, 0.06 * dt);
                        if (has_spear) {
                            pd.stagger_timer = 1.4;
                            e.addSkill(.toolcraft, 0.08 * dt);
                            e.tool_durability -= 4.5 * dt;
                            if (e.tool_durability <= 0) e.tool = .none;
                        }
                        if (e.call_cooldown <= 0) w.emitSignal(i, .danger_call, pd.pos);
                        if (pd.hp <= 0) {
                            e.kills += 1;
                            e.addSkill(.combat, 0.14);
                            e.addSkill(.toolcraft, 0.18);
                            e.genome.cog.learn(1.5);
                            _ = e.genome.cog.sproutFromExperience(w.rng());
                            w.stats[e.society].predators_slain += 1;
                            w.pushEvent(e.society, .predator_slain, w.stats[e.society].predators_slain);
                            // Massive trophy harvest so collective defense pays off enormously!
                            for (0..4) |k| {
                                const ang = @as(f32, @floatFromInt(k)) * (std.math.tau / 4.0);
                                try w.resources.append(w.gpa, .{
                                    .pos = .{ .x = pd.pos.x + 12 * @cos(ang), .y = pd.pos.y + 12 * @sin(ang) },
                                    .food = if (k < 2) .meat else .universal,
                                    .amount = 50,
                                    .patch = null,
                                    .corpse = false,
                                });
                            }
                            w.field.deposit(scentChannel(.universal), pd.pos.x, pd.pos.y, 4.0);
                            w.field.deposit(scentChannel(.meat), pd.pos.x, pd.pos.y, 4.0);
                        }
                    }
                }
            }
        }

        // Combat (within physical reach); combat skill and Stone Spears improve offense & reach.
        if (e.action == .fight) {
            if (e.enemy) |oi| {
                const o = &w.entities.items[oi];
                const has_spear = e.tool == .spear;
                const creach = e.radius() + o.radius() + (if (has_spear) @as(f32, 14) else 4);
                if (o.dead == null and o.pos.dist(e.pos) < creach) {
                    const spear_mult: f32 = if (has_spear) 1.55 + 0.35 * e.skill(.toolcraft) else 1.0;
                    const atk = (8 + 22 * g.trait(.aggression)) * (1 + 0.4 * e.skill(.combat)) * spear_mult;
                    const dmg = atk * (1 - 0.3 * o.skill(.combat)) * dt;
                    o.energy -= dmg;
                    e.energy -= 3 * dt;
                    e.addSkill(.combat, dt * 0.05);
                    if (has_spear) {
                        e.addSkill(.toolcraft, dt * 0.04);
                        e.tool_durability -= 5.0 * dt;
                        if (e.tool_durability <= 0) e.tool = .none;
                    }
                    o.addSkill(.combat, dt * 0.03);
                    o.genome.cog.learn(-dmg * 0.12);
                    if (!w.forage_only) {
                        o.remember(.danger, e.pos, 0.90);
                        o.adjustTrust(e.id, -0.55 * dt);
                        o.genome.cog.noradrenaline = @min(1, o.genome.cog.noradrenaline + 0.5 * dt);
                    }
                    if (!w.forage_only and o.call_cooldown <= 0) w.emitSignal(oi, .danger_call, e.pos);
                    w.field.deposit(alarmChannel(o.society), o.pos.x, o.pos.y, dmg * 0.6);
                    if (o.energy <= 0 and o.dead == null) {
                        const is_cannibal = o.society == e.society;
                        e.kills += 1;
                        e.addSkill(.combat, 0.08);
                        e.genome.cog.learn(0.6);
                        if (is_cannibal) {
                            e.cannibal_kills += 1;
                            const st = &w.stats[e.society];
                            st.cannibal_kills += 1;
                            if (!st.had_cannibalism or st.cannibal_kills % 10 == 0) {
                                st.had_cannibalism = true;
                                w.pushEvent(e.society, .cannibalism, st.cannibal_kills);
                            }
                        }
                        try w.killCorpse(oi, .killed, if (has_spear) 50 else 30);
                    }
                }
            }
        }

        // Any two ready mature adults that court (or share high surplus/trust) and meet can breed.
        if (e.mate) |oi| {
            const o = &w.entities.items[oi];
            const willing = e.action == .mate or o.action == .mate or (e.energy > 95 and o.energy > 95) or e.trustOf(o.id) > 0.25;
            if (willing and o.pos.dist(e.pos) < e.radius() + o.radius() + 6 and e.readyToMate() and o.readyToMate()) {
                try w.reproduce(i, oi);
            }
        }

        const me = &w.entities.items[i];
        if (me.dead == null) {
            if (me.energy <= 0) try w.kill(i, .starved) else if (me.age > me.lifespan) try w.kill(i, .old_age);
        }
    }

    fn tryBuild(w: *World, i: usize) !void {
        const e = &w.entities.items[i];
        const bskill = e.skill(.building);
        // 1. Stigmergy: contribute to a nearby incomplete or damaged friendly structure.
        if (e.near_structure) |si| {
            const st = &w.structures.items[si];
            if ((!st.complete() or st.integrity < 85) and st.pos.dist(e.pos) < st.radius() + 18) {
                const was_complete = st.complete();
                if (!was_complete) {
                    st.progress = @min(100, st.progress + 34 + 28 * bskill);
                } else {
                    st.integrity = @min(100, st.integrity + 35 + 20 * bskill);
                }
                e.carrying = .none;
                e.energy -= 2.0;
                e.addSkill(.building, 0.28);
                e.genome.cog.learn(0.85);
                _ = e.genome.cog.sproutFromExperience(w.rng());
                if (!was_complete and st.complete()) {
                    e.remember(.shelter, st.pos, 0.95);
                    const stats = &w.stats[e.society];
                    stats.structures_built += 1;
                    if (!stats.discovered_building) {
                        stats.discovered_building = true;
                        w.pushEvent(e.society, .building_discovered, @backingInt(st.kind));
                    }
                }
                return;
            }
        }
        // 2. Start a new foundation inside territory or near strong kin trail if spaced clear of others.
        const in_home = w.territories[e.society].contains(e.pos);
        const kin_trail = w.field.sample(trailChannel(e.society), e.pos.x, e.pos.y);
        if (!in_home and kin_trail < 0.25) return;

        var soc_count: usize = 0;
        var shelters: usize = 0;
        var caches: usize = 0;
        for (w.structures.items) |st| {
            if (st.integrity <= 0) continue;
            if (st.pos.dist(e.pos) < 88) return; // keep structures cleanly spaced
            if (st.society == e.society) {
                soc_count += 1;
                if (st.kind == .shelter) shelters += 1 else caches += 1;
            }
        }
        if (soc_count >= max_structures_per_society) return;

        // Stone naturally forms sturdy Shelters; wood forms Food Caches when needed or light Shelters.
        const kind: StructureKind = if (e.carrying == .stone)
            .shelter
        else if (caches < shelters or caches == 0)
            .cache
        else
            .shelter;
        try w.structures.append(w.gpa, .{
            .pos = e.pos,
            .society = e.society,
            .kind = kind,
            .progress = 34 + 20 * bskill,
            .builder_id = e.id,
        });
        e.carrying = .none;
        e.energy -= 2.5;
        e.addSkill(.building, 0.14);
        e.genome.cog.learn(0.65);
        _ = e.genome.cog.sproutFromExperience(w.rng());
    }

    fn kill(w: *World, i: usize, cause: Death) !void {
        try w.killCorpse(i, cause, 30);
    }

    fn killCorpse(w: *World, i: usize, cause: Death, corpse_amount: f32) !void {
        const e = &w.entities.items[i];
        e.dead = cause;
        w.stats[e.society].deaths[@backingInt(cause)] += 1;
        w.field.deposit(alarmChannel(e.society), e.pos.x, e.pos.y, 8);
        if (cause != .old_age or w.rng().boolean()) {
            try w.resources.append(w.gpa, .{ .pos = e.pos, .food = .meat, .amount = corpse_amount, .patch = null, .corpse = true });
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
        // Generational landmark knowledge: child inherits parents' strongest shelter or food memory.
        for ([_]Entity{ a, b }) |parent| {
            if (parent.recall(.shelter, 0.35)) |si| {
                child.remember(.shelter, parent.memories[si].pos, parent.memories[si].confidence * 0.6);
            } else if (parent.recall(.food, 0.35)) |fi| {
                child.remember(.food, parent.memories[fi].pos, parent.memories[fi].confidence * 0.55);
            }
        }
        child.adjustTrust(a.id, 0.6);
        child.adjustTrust(b.id, 0.6);

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
            p.repro_cooldown = if (p.stage() == .elder) 180 else 90;
            p.children += 1;
            p.addSkill(.care, 0.05);
            p.genome.cog.learn(0.8);
            p.adjustTrust(if (pi == ai) b.id else a.id, 0.4);
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
        const t = @mod(w.time + w.phase_offset, cycle_length);
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
        sender.addSkill(.care, 0.004);
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
    /// Uses the spatial hash grid so uncapped populations stay O(N).
    fn resolveCollisions(w: *World) !void {
        const items = w.entities.items;
        const n = items.len;
        if (n < 2) return;

        for (0..3) |iter| {
            try w.rebuildGrid();
            for (0..n) |i| {
                const a = &items[i];
                if (a.dead != null) continue;
                const ra = a.radius();
                const cc = cellCoords(a.pos);
                const x0: usize = cc[0] -| 1;
                const x1: usize = @min(grid_cols - 1, cc[0] + 1);
                const y0: usize = cc[1] -| 1;
                const y1: usize = @min(grid_rows - 1, cc[1] + 1);
                for (y0..y1 + 1) |gy| {
                    for (x0..x1 + 1) |gx| {
                        var cur = w.grid_head[gy * grid_cols + gx];
                        while (cur >= 0) {
                            const j: usize = @intCast(cur);
                            cur = w.grid_next.items[j];
                            if (j <= i) continue;
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
        }

        // Solid collisions between entities and Wild Prey / Apex Predators (never ghosting through!).
        if (!w.forage_only) {
            for (w.prey.items) |*pr| {
                if (pr.hp <= 0) continue;
                const rp = pr.radius();
                const mp = rp * rp * 2.0;
                const cc = cellCoords(pr.pos);
                const x0: usize = cc[0] -| 1;
                const x1: usize = @min(grid_cols - 1, cc[0] + 1);
                const y0: usize = cc[1] -| 1;
                const y1: usize = @min(grid_rows - 1, cc[1] + 1);
                for (y0..y1 + 1) |gy| {
                    for (x0..x1 + 1) |gx| {
                        var cur = w.grid_head[gy * grid_cols + gx];
                        while (cur >= 0) {
                            const ei: usize = @intCast(cur);
                            cur = w.grid_next.items[ei];
                            const e = &items[ei];
                            if (e.dead != null) continue;
                            const re = e.radius();
                            const min_d = re + rp;
                            const dx = e.pos.x - pr.pos.x;
                            const dy = e.pos.y - pr.pos.y;
                            const d2 = dx * dx + dy * dy;
                            if (d2 >= min_d * min_d) continue;
                            const dist = if (d2 > 1e-6) @sqrt(d2) else 0.001;
                            const nx = if (d2 > 1e-6) dx / dist else 1;
                            const ny = if (d2 > 1e-6) dy / dist else 0;
                            const pen = min_d - dist;
                            const me = re * re;
                            const inv = 1.0 / (me + mp);
                            e.pos.x += nx * pen * mp * inv;
                            e.pos.y += ny * pen * mp * inv;
                            pr.pos.x -= nx * pen * me * inv;
                            pr.pos.y -= ny * pen * me * inv;
                            if (e.bump_cooldown <= 0) {
                                e.bump_cooldown = 0.4;
                                e.resting = false;
                                e.bump_vel.x += nx * 28;
                                e.bump_vel.y += ny * 28;
                                e.remember(.prey, pr.pos, 0.7);
                                pr.flee_timer = @max(pr.flee_timer, 1.2);
                                pr.heading = std.math.atan2(-ny, -nx);
                            }
                        }
                    }
                }
            }

            for (w.predators.items) |*pd| {
                if (pd.hp <= 0) continue;
                const rp = pd.radius();
                const mp = rp * rp * 2.5;
                // Completed Shelters physically block Apex Predators from entering!
                for (w.structures.items) |*st| {
                    if (!st.complete() or st.kind != .shelter or st.integrity <= 0) continue;
                    const min_s = st.radius() + rp;
                    const dx = pd.pos.x - st.pos.x;
                    const dy = pd.pos.y - st.pos.y;
                    const d2 = dx * dx + dy * dy;
                    if (d2 < min_s * min_s) {
                        const dist = if (d2 > 1e-6) @sqrt(d2) else 0.001;
                        const nx = if (d2 > 1e-6) dx / dist else 1;
                        const ny = if (d2 > 1e-6) dy / dist else 0;
                        pd.pos.x = st.pos.x + nx * min_s;
                        pd.pos.y = st.pos.y + ny * min_s;
                        pd.heading = std.math.atan2(ny, nx);
                        st.integrity -= 0.15; // predator batters the shelter wall slightly
                        w.field.deposit(alarmChannel(st.society), st.pos.x, st.pos.y, 1.2);
                    }
                }

                const cc = cellCoords(pd.pos);
                const x0: usize = cc[0] -| 1;
                const x1: usize = @min(grid_cols - 1, cc[0] + 1);
                const y0: usize = cc[1] -| 1;
                const y1: usize = @min(grid_rows - 1, cc[1] + 1);
                for (y0..y1 + 1) |gy| {
                    for (x0..x1 + 1) |gx| {
                        var cur = w.grid_head[gy * grid_cols + gx];
                        while (cur >= 0) {
                            const ei: usize = @intCast(cur);
                            cur = w.grid_next.items[ei];
                            const e = &items[ei];
                            if (e.dead != null) continue;
                            const re = e.radius();
                            const min_d = re + rp;
                            const dx = e.pos.x - pd.pos.x;
                            const dy = e.pos.y - pd.pos.y;
                            const d2 = dx * dx + dy * dy;
                            if (d2 >= min_d * min_d) continue;
                            const dist = if (d2 > 1e-6) @sqrt(d2) else 0.001;
                            const nx = if (d2 > 1e-6) dx / dist else 1;
                            const ny = if (d2 > 1e-6) dy / dist else 0;
                            const pen = min_d - dist;
                            const me = re * re;
                            const inv = 1.0 / (me + mp);
                            e.pos.x += nx * pen * mp * inv;
                            e.pos.y += ny * pen * mp * inv;
                            pd.pos.x -= nx * pen * me * inv;
                            pd.pos.y -= ny * pen * me * inv;
                            if (e.bump_cooldown <= 0) {
                                e.bump_cooldown = 0.35;
                                e.resting = false;
                                e.action_timer = 0;
                                e.bump_vel.x += nx * 58;
                                e.bump_vel.y += ny * 58;
                                e.remember(.danger, pd.pos, 1.0);
                                w.field.deposit(alarmChannel(e.society), e.pos.x, e.pos.y, 2.5);
                                w.addContact(e.pos, .rival_clash, e.society);
                            }
                        }
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

        if (a.society == b.society and !a.cannibal_target and !b.cannibal_target) {
            // Kin slide smoothly past each other along the tangent instead of bouncing off their trail.
            const tx = -ny;
            const ty = nx;
            const a_side: f32 = if (@cos(a.heading) * tx + @sin(a.heading) * ty >= 0) 1 else -1;
            const b_side: f32 = if (@cos(b.heading) * tx + @sin(b.heading) * ty >= 0) 1 else -1;
            a.bump_vel.x += tx * a_side * 8 - nx * 4;
            a.bump_vel.y += ty * a_side * 8 - ny * 4;
            b.bump_vel.x += tx * b_side * 8 + nx * 4;
            b.bump_vel.y += ty * b_side * 8 + ny * 4;

            // Mentorship & storytelling: experienced kin pass down learned skills and spatial memories!
            mentorKin(a, b);
            mentorKin(b, a);
            if (!w.forage_only) {
                shareMemory(a, b);
                shareMemory(b, a);
            }

            if (a.readyToMate() and b.readyToMate()) {
                w.addContact(mid, .courtship, a.society);
                return;
            }
            // Trophallaxis: a well-fed, sociable kin shares a small bit of energy with a hungry one.
            if (tryShareFood(w, a, b, mid) or tryShareFood(w, b, a, mid)) return;

            // Antennation: a recently fed kin leaves a quick trail cue for a hungry kin.
            if (a.since_meal < 8 and b.since_meal > 10) {
                w.field.deposit(trailChannel(a.society), mid.x, mid.y, 0.8);
                a.addSkill(.care, 0.006);
                w.addContact(mid, .kin_greet, a.society);
            } else if (b.since_meal < 8 and a.since_meal > 10) {
                w.field.deposit(trailChannel(b.society), mid.x, mid.y, 0.8);
                b.addSkill(.care, 0.006);
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
        const trust = donor.trustOf(receiver.id);
        const nurturing_youth = donor.mature() and !receiver.mature();
        const min_donor: f32 = if (nurturing_youth) 78 else if (trust > 0.3) 90 else 105;
        const max_recv: f32 = if (nurturing_youth) 85 else 75;
        if (donor.energy > min_donor and receiver.energy < max_recv and (nurturing_youth or donor.genome.trait(.sociability) > 0.45 or trust > 0.35)) {
            const gift: f32 = (if (nurturing_youth) @as(f32, 8) else 6) + 4 * donor.skill(.care);
            donor.energy -= gift;
            receiver.energy = @min(max_energy, receiver.energy + gift);
            receiver.since_meal = @min(receiver.since_meal, 4);
            donor.addSkill(.care, 0.06);
            donor.genome.cog.learn(0.35);
            receiver.genome.cog.learn(0.4);
            donor.adjustTrust(receiver.id, 0.30);
            receiver.adjustTrust(donor.id, 0.45);
            w.field.deposit(trailChannel(donor.society), mid.x, mid.y, 1.0);
            w.addContact(mid, .share_food, donor.society);
            return true;
        }
        return false;
    }

    fn shareMemory(teller: *const Entity, listener: *Entity) void {
        // Share strongest food, shelter, or recent danger memory with kin.
        for ([_]MemoryKind{ .food, .shelter, .danger }) |kind| {
            if (teller.recall(kind, 0.48)) |mi| {
                const mem = teller.memories[mi];
                listener.remember(kind, mem.pos, mem.confidence * 0.72);
            }
        }
    }

    fn mentorKin(mentor: *Entity, student: *Entity) void {
        if (!mentor.mature()) return;
        const elder_boost: f32 = if (mentor.stage() == .elder or mentor.role() == .elder) 0.7 else 0;
        const youth_absorb: f32 = switch (student.stage()) {
            .infant => 1.8,
            .juvenile => 1.35,
            else => 1.0,
        };
        const rate = 0.06 * (0.6 + mentor.skill(.care) + elder_boost) * youth_absorb;
        var taught = false;
        for (0..skill_count) |si| {
            const diff = mentor.skills[si] - student.skills[si];
            if (diff > 0.08) {
                student.addSkill(@fromBackingInt(@intCast(si)), diff * rate);
                taught = true;
            }
        }
        if (taught) {
            mentor.addSkill(.care, 0.006);
            mentor.adjustTrust(student.id, 0.15);
            student.adjustTrust(mentor.id, 0.22);
        }
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

/// Signed egocentric bearing from `heading` to `target` in [-1, +1] (-0.5 left, 0 ahead, +0.5 right).
fn egocentricBearing(heading: f32, pos: Vec2, target: Vec2) f32 {
    const want = std.math.atan2(target.y - pos.y, target.x - pos.x);
    const diff = @mod(want - heading + std.math.pi, std.math.tau) - std.math.pi;
    return std.math.clamp(diff / std.math.pi, -1, 1);
}

/// Angular velocity that turns `heading` toward `target`.
fn steerTo(heading: f32, pos: Vec2, target: Vec2, rate: f32) f32 {
    const want = std.math.atan2(target.y - pos.y, target.x - pos.x);
    var diff = want - heading;
    diff = @mod(diff + std.math.pi, std.math.tau) - std.math.pi;
    return std.math.clamp(diff * rate, -rate, rate);
}
