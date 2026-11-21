//! Automatic CSV telemetry logger for analyzing emergent behaviours,
//! trait drift, skill inheritance, cognitive brain growth, and survival.

const std = @import("std");
const sim = @import("world.zig");
const gen = @import("genome.zig");

const FILE = opaque {};
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fflush(stream: *FILE) c_int;
extern "c" fn fclose(stream: *FILE) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;

pub const RunLogger = struct {
    file: ?*FILE = null,
    interval: f32 = 10.0,
    next_time: f32 = 0.0,
    path_buf: [256]u8 = @splat(0),
    path_len: usize = 0,

    pub fn init(seed: u64, custom_path: ?[:0]const u8) RunLogger {
        var self = RunLogger{};
        if (custom_path) |p| {
            const n = @min(p.len, self.path_buf.len - 1);
            @memcpy(self.path_buf[0..n], p[0..n]);
            self.path_buf[n] = 0;
            self.path_len = n;
        } else {
            _ = mkdir("data", 0o755);
            _ = mkdir("data/world_states", 0o755);
            const slice = std.fmt.bufPrint(self.path_buf[0 .. self.path_buf.len - 1], "data/world_states/run_{d}.csv", .{seed}) catch return self;
            self.path_buf[slice.len] = 0;
            self.path_len = slice.len;
        }
        const f = fopen(@ptrCast(&self.path_buf), "w") orelse return self;
        self.file = f;
        self.writeAll(
            "time,phase,scarcity,society,pop,hybrids,births,starved,old_age,killed," ++
                "avg_gen,max_gen,avg_energy," ++
                "avg_speed,avg_efficiency,avg_aggression,avg_sociability,avg_territoriality,avg_trail_output,avg_adaptability,avg_fertility," ++
                "avg_foraging,avg_navigation,avg_combat,avg_care,avg_building,avg_toolcraft," ++
                "avg_neurons,avg_synapses,outside_home_frac,huddled_frac,active_lineages," ++
                "foragers,scouts,guards,caretakers,builders,hunters,elders," ++
                "signals_sent,signals_acted,cannibal_kills,tools_held,structures_built,prey_hunted\n",
        );
        return self;
    }

    pub fn path(self: *const RunLogger) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn deinit(self: *RunLogger) void {
        if (self.file) |f| {
            _ = fflush(f);
            _ = fclose(f);
            self.file = null;
        }
    }

    pub fn maybeLog(self: *RunLogger, w: *const sim.World) void {
        if (self.file == null) return;
        if (w.time < self.next_time) return;
        self.logNow(w);
        self.next_time = w.time + self.interval;
    }

    pub fn logNow(self: *RunLogger, w: *const sim.World) void {
        const f = self.file orelse return;
        var line: [512]u8 = undefined;
        for (sim.societies, 0..) |soc, si| {
            var pop: u32 = 0;
            var hybrids: u32 = 0;
            var gen_sum: f32 = 0;
            var energy_sum: f32 = 0;
            var traits: [gen.trait_count]f32 = @splat(0);
            var skills: [sim.skill_count]f32 = @splat(0);
            var neurons: f32 = 0;
            var synapses: f32 = 0;
            var outside: u32 = 0;
            var huddled: u32 = 0;
            var tools_held: u32 = 0;
            var roles: [sim.role_count]u32 = @splat(0);
            var lineages: [128]u32 = undefined;
            var lin_count: usize = 0;

            for (w.entities.items) |*e| {
                if (e.dead != null or e.society != si) continue;
                pop += 1;
                if (e.hybrid) hybrids += 1;
                gen_sum += @floatFromInt(e.generation);
                energy_sum += e.energy;
                for (&traits, e.genome.traits) |*t, v| t.* += v;
                for (&skills, e.skills) |*s, v| s.* += v;
                neurons += @floatFromInt(e.genome.cog.totalNeurons());
                synapses += @floatFromInt(e.genome.cog.activeSynapses());
                if (!w.territories[si].contains(e.pos)) outside += 1;
                if (e.huddled) huddled += 1;
                if (e.tool != .none) tools_held += 1;
                roles[@backingInt(e.role())] += 1;
                var seen = false;
                for (lineages[0..lin_count]) |lid| {
                    if (lid == e.lineage) {
                        seen = true;
                        break;
                    }
                }
                if (!seen and lin_count < lineages.len) {
                    lineages[lin_count] = e.lineage;
                    lin_count += 1;
                }
            }

            const d: f32 = if (pop > 0) @floatFromInt(pop) else 1;
            const st = w.stats[si];
            const out_frac: f32 = if (pop > 0) @as(f32, @floatFromInt(outside)) / d else 0;
            const hud_frac: f32 = if (pop > 0) @as(f32, @floatFromInt(huddled)) / d else 0;

            const s1 = std.fmt.bufPrint(
                &line,
                "{d:.1},{s},{s},{s},{d},{d},{d},{d},{d},{d},{d:.2},{d},{d:.1}," ++
                    "{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},",
                .{
                    w.time,
                    @tagName(w.phase),
                    @tagName(w.scarcity),
                    soc.name,
                    pop,
                    hybrids,
                    st.births,
                    st.deaths[0],
                    st.deaths[1],
                    st.deaths[2],
                    gen_sum / d,
                    st.max_gen,
                    energy_sum / d,
                    traits[0] / d,
                    traits[1] / d,
                    traits[2] / d,
                    traits[3] / d,
                    traits[4] / d,
                    traits[5] / d,
                    traits[6] / d,
                    traits[7] / d,
                },
            ) catch continue;
            self.writeAll(s1);

            const s2 = std.fmt.bufPrint(
                &line,
                "{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.2},{d:.2},{d:.3},{d:.3},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n",
                .{
                    skills[0] / d,
                    skills[1] / d,
                    skills[2] / d,
                    skills[3] / d,
                    skills[4] / d,
                    skills[5] / d,
                    neurons / d,
                    synapses / d,
                    out_frac,
                    hud_frac,
                    lin_count,
                    roles[@backingInt(sim.Role.forager)],
                    roles[@backingInt(sim.Role.scout)],
                    roles[@backingInt(sim.Role.guard)],
                    roles[@backingInt(sim.Role.caretaker)],
                    roles[@backingInt(sim.Role.builder)],
                    roles[@backingInt(sim.Role.hunter)],
                    roles[@backingInt(sim.Role.elder)],
                    st.signals_sent,
                    st.signals_acted,
                    st.cannibal_kills,
                    tools_held,
                    st.structures_built,
                    st.prey_hunted,
                },
            ) catch continue;
            self.writeAll(s2);
        }
        _ = fflush(f);
    }

    fn writeAll(self: *RunLogger, bytes: []const u8) void {
        const f = self.file orelse return;
        _ = fwrite(bytes.ptr, 1, bytes.len, f);
    }
};
