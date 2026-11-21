//! Heritable material: body traits, fly-circuit cell-type gains, motor
//! gains, and a growing, plastic cognitive network (NEAT-style neurogenesis,
//! synaptogenesis, synaptic pruning, and reward-modulated Hebbian learning).

const std = @import("std");
const Random = std.Random;

pub const Trait = enum(u8) {
    speed,
    efficiency, // lower energy drain
    aggression, // combat damage
    sociability, // preferred distance to kin
    territoriality, // how far from home they roam
    trail_output, // pheromone laid after eating
    adaptability, // can digest other societies' food
    fertility, // lower reproduction threshold
};
pub const trait_count = @typeInfo(Trait).@"enum".field_names.len;

/// How fly motor output becomes movement.
pub const MotorGene = enum(u8) {
    turn, // rad/s per unit of left-right DN difference
    forward, // speed boost per unit of DNp09
    feed_threshold, // MN9 activity needed to eat
    wander, // random turning noise
    smell, // ORN drive per unit of odour
};
pub const motor_count = @typeInfo(MotorGene).@"enum".field_names.len;

/// Growing cognitive network node layout (strictly feed-forward: from < to).
///   0 .. social_inputs-1                     : sensory / state inputs
///   social_inputs .. social_inputs+max_cog_hidden-1 : evolvable hidden neurons
///   out_base .. max_cog_nodes-1              : action output neurons
pub const social_inputs = 16;
pub const SocialAction = enum(u8) { forage, fight, mate, socialize, flee, gather, craft_tool, build };
pub const social_outputs = @typeInfo(SocialAction).@"enum".field_names.len;
pub const max_cog_hidden = 24;
pub const out_base = social_inputs + max_cog_hidden;
pub const max_cog_nodes = out_base + social_outputs;
pub const max_cog_synapses = 224;

pub const Synapse = struct {
    from: u8,
    to: u8,
    weight: f32,
    active: bool = true,
};

pub const CognitiveBrain = struct {
    hidden_count: u8 = 4,
    synapse_count: u16 = 0,
    synapses: [max_cog_synapses]Synapse = undefined,
    bias: [max_cog_hidden + social_outputs]f32 = @splat(0),
    /// Runtime activations for Hebbian plasticity & live visualization.
    act: [max_cog_nodes]f32 = @splat(0),
    /// Decaying pre*post eligibility traces for reward-modulated learning.
    elig: [max_cog_synapses]f32 = @splat(0),
    /// Synapses sprouted through lifetime experience.
    lifetime_rewires: u16 = 0,

    pub fn totalNeurons(b: *const CognitiveBrain) u32 {
        return @as(u32, @intCast(social_inputs + social_outputs)) + b.hidden_count;
    }

    pub fn activeSynapses(b: *const CognitiveBrain) u32 {
        var n: u32 = 0;
        for (b.synapses[0..b.synapse_count]) |s| {
            if (s.active) n += 1;
        }
        return n;
    }

    pub fn random(rng: Random) CognitiveBrain {
        var b = CognitiveBrain{ .hidden_count = 4 };
        for (&b.bias) |*v| v.* = rng.floatNorm(f32) * 0.25;
        // Founders lean toward foraging; curious individuals stumble onto gathering,
        // tool-crafting, and building and lock them in through reward plasticity.
        b.bias[max_cog_hidden + @backingInt(SocialAction.forage)] += 1.35;
        b.bias[max_cog_hidden + @backingInt(SocialAction.gather)] += 0.15;
        b.bias[max_cog_hidden + @backingInt(SocialAction.craft_tool)] += 0.10;
        b.bias[max_cog_hidden + @backingInt(SocialAction.build)] += 0.10;

        // Compact starter wiring: sparse input -> hidden and hidden -> output.
        for (0..b.hidden_count) |hi| {
            const h_node: u8 = @intCast(social_inputs + hi);
            for (0..social_inputs) |ii| {
                if (rng.float(f32) < 0.42) {
                    _ = b.insertSynapse(@intCast(ii), h_node, rng.floatNorm(f32) * 0.6);
                }
            }
            for (0..social_outputs) |oi| {
                const o_node: u8 = @intCast(out_base + oi);
                _ = b.insertSynapse(h_node, o_node, rng.floatNorm(f32) * 0.6);
            }
        }
        return b;
    }

    pub fn child(rng: Random, a: *const CognitiveBrain, b_parent: *const CognitiveBrain, rate: f32) CognitiveBrain {
        // Inherit topology from the richer parent (or random tie-break) and recombine matching synapses.
        const primary = if (a.hidden_count > b_parent.hidden_count or (a.hidden_count == b_parent.hidden_count and rng.boolean())) a else b_parent;
        const secondary = if (primary == a) b_parent else a;

        var c = CognitiveBrain{
            .hidden_count = primary.hidden_count,
            .synapse_count = 0,
            .bias = primary.bias,
        };
        for (&c.bias, secondary.bias) |*bv, sv| {
            const pick = if (rng.boolean()) bv.* else sv;
            bv.* = std.math.clamp(pick + mutation(rng, rate, 0.14), -4, 4);
        }

        for (primary.synapses[0..primary.synapse_count]) |s| {
            if (!s.active) continue;
            var w = s.weight;
            if (secondary.findSynapse(s.from, s.to)) |other_w| {
                w = if (rng.boolean()) w else other_w;
            }
            w = std.math.clamp(w + mutation(rng, rate, 0.16), -4, 4);
            _ = c.insertSynapse(s.from, s.to, w);
        }

        // Structural evolution: synaptogenesis, neurogenesis, and pruning.
        if (rng.float(f32) < 0.16) _ = c.addRandomSynapse(rng);
        if (rng.float(f32) < 0.08) _ = c.addNeuron(rng);
        if (rng.float(f32) < 0.10) c.pruneWeak();
        return c;
    }

    pub fn findSynapse(b: *const CognitiveBrain, from: u8, to: u8) ?f32 {
        for (b.synapses[0..b.synapse_count]) |s| {
            if (s.active and s.from == from and s.to == to) return s.weight;
        }
        return null;
    }

    fn insertSynapse(b: *CognitiveBrain, from: u8, to: u8, weight: f32) bool {
        if (from >= to) return false;
        if (b.findSynapse(from, to) != null) return false;
        if (b.synapse_count >= max_cog_synapses) return false;
        b.synapses[b.synapse_count] = .{ .from = from, .to = to, .weight = weight, .active = true };
        b.elig[b.synapse_count] = 0;
        b.synapse_count += 1;
        return true;
    }

    /// Synaptogenesis: connect two previously unlinked feed-forward nodes.
    pub fn addRandomSynapse(b: *CognitiveBrain, rng: Random) bool {
        const src_pool = social_inputs + @as(usize, b.hidden_count);
        const dst_pool = @as(usize, b.hidden_count) + social_outputs;
        for (0..12) |_| {
            const from: u8 = @intCast(rng.uintLessThan(usize, src_pool));
            const pick = rng.uintLessThan(usize, dst_pool);
            const to: u8 = if (pick < b.hidden_count)
                @intCast(social_inputs + pick)
            else
                @intCast(out_base + (pick - b.hidden_count));
            if (from < to and b.insertSynapse(from, to, rng.floatNorm(f32) * 0.4)) {
                return true;
            }
        }
        return false;
    }

    /// Neurogenesis: split an active synapse ending at an output node to insert a new hidden neuron.
    pub fn addNeuron(b: *CognitiveBrain, rng: Random) bool {
        if (b.hidden_count >= max_cog_hidden) return false;
        if (b.synapse_count + 2 > max_cog_synapses) return false;

        // Collect active synapses targeting output nodes (guaranteed from < new_hidden < to).
        var candidates: [max_cog_synapses]u16 = undefined;
        var count: usize = 0;
        for (b.synapses[0..b.synapse_count], 0..) |s, i| {
            if (s.active and s.to >= out_base) {
                candidates[count] = @intCast(i);
                count += 1;
            }
        }
        if (count == 0) return false;

        const idx = candidates[rng.uintLessThan(usize, count)];
        const old = b.synapses[idx];
        const new_node: u8 = @intCast(social_inputs + b.hidden_count);
        b.hidden_count += 1;
        b.bias[new_node - social_inputs] = 0;
        b.synapses[idx].active = false;
        _ = b.insertSynapse(old.from, new_node, 1.0);
        _ = b.insertSynapse(new_node, old.to, old.weight);
        return true;
    }

    /// Synaptic pruning: remove near-zero connections once the network has room to spare.
    fn pruneWeak(b: *CognitiveBrain) void {
        if (b.activeSynapses() <= 28) return;
        for (b.synapses[0..b.synapse_count]) |*s| {
            if (s.active and @abs(s.weight) < 0.035) {
                s.active = false;
                return;
            }
        }
    }

    /// Feed-forward pass; updates runtime activations and Hebbian eligibility traces.
    pub fn decide(b: *CognitiveBrain, in: [social_inputs]f32) SocialAction {
        @memset(&b.act, 0);
        for (in, 0..) |x, i| b.act[i] = x;

        var accum: [max_cog_nodes]f32 = @splat(0);
        for (0..b.hidden_count) |hi| accum[social_inputs + hi] = b.bias[hi];
        for (0..social_outputs) |oi| accum[out_base + oi] = b.bias[max_cog_hidden + oi];

        // Evaluate hidden nodes in topological order (all synapses satisfy from < to).
        for (0..b.hidden_count) |hi| {
            const node: u8 = @intCast(social_inputs + hi);
            var sum = accum[node];
            for (b.synapses[0..b.synapse_count]) |s| {
                if (s.active and s.to == node) sum += s.weight * b.act[s.from];
            }
            b.act[node] = std.math.tanh(sum);
        }

        // Evaluate output logits.
        var best: usize = 0;
        var best_val: f32 = -std.math.inf(f32);
        for (0..social_outputs) |oi| {
            const node: u8 = @intCast(out_base + oi);
            var sum = accum[node];
            for (b.synapses[0..b.synapse_count]) |s| {
                if (s.active and s.to == node) sum += s.weight * b.act[s.from];
            }
            b.act[node] = std.math.tanh(sum);
            if (sum > best_val) {
                best_val = sum;
                best = oi;
            }
        }

        // Update decaying Hebbian eligibility traces (pre * post).
        for (b.synapses[0..b.synapse_count], b.elig[0..b.synapse_count]) |s, *el| {
            if (!s.active) {
                el.* = 0;
                continue;
            }
            el.* = 0.72 * el.* + 0.28 * b.act[s.from] * b.act[s.to];
        }

        return @fromBackingInt(@intCast(best));
    }

    /// Reward-modulated Hebbian plasticity: strengthen co-active paths on reward, weaken on harm.
    pub fn learn(b: *CognitiveBrain, reward: f32) void {
        if (@abs(reward) < 1e-4) return;
        const lr: f32 = 0.045;
        for (b.synapses[0..b.synapse_count], b.elig[0..b.synapse_count]) |*s, el| {
            if (!s.active or @abs(el) < 1e-4) continue;
            const delta = std.math.clamp(lr * reward * el, -0.08, 0.08);
            s.weight = std.math.clamp(s.weight + delta, -4, 4);
        }
    }

    /// Experience-driven developmental synaptogenesis during a creature's lifetime.
    pub fn sproutFromExperience(b: *CognitiveBrain, rng: Random) bool {
        if (b.lifetime_rewires >= 4) return false;
        if (b.addRandomSynapse(rng)) {
            b.lifetime_rewires += 1;
            return true;
        }
        return false;
    }
};

pub const Genome = struct {
    traits: [trait_count]f32,
    motor: [motor_count]f32,
    cog: CognitiveBrain,
    fly_gain: []f32, // one per cell type in the circuit

    pub fn trait(g: *const Genome, t: Trait) f32 {
        return g.traits[@backingInt(t)];
    }
    pub fn motorGene(g: *const Genome, m: MotorGene) f32 {
        return g.motor[@backingInt(m)];
    }

    pub fn random(gpa: std.mem.Allocator, rng: Random, cell_types: usize) !Genome {
        var g: Genome = undefined;
        for (&g.traits) |*t| t.* = rng.float(f32);
        g.motor = motor_defaults;
        for (&g.motor, motor_spread) |*m, s| m.* *= 1 + s * rng.floatNorm(f32);
        g.cog = CognitiveBrain.random(rng);
        g.fly_gain = try gpa.alloc(f32, cell_types);
        for (g.fly_gain) |*w| w.* = @max(0, 1 + 0.15 * rng.floatNorm(f32));
        return g;
    }

    pub fn child(gpa: std.mem.Allocator, rng: Random, a: *const Genome, b: *const Genome, rate: f32) !Genome {
        var g: Genome = undefined;
        for (&g.traits, a.traits, b.traits) |*t, x, y| {
            t.* = std.math.clamp((x + y) / 2 + mutation(rng, rate, 0.08), 0, 1);
        }
        for (&g.motor, a.motor, b.motor, motor_defaults) |*m, x, y, d| {
            const pick = if (rng.boolean()) x else y;
            m.* = @max(0, pick + mutation(rng, rate, 0.1 * d));
        }
        g.cog = CognitiveBrain.child(rng, &a.cog, &b.cog, rate);
        g.fly_gain = try gpa.alloc(f32, a.fly_gain.len);
        for (g.fly_gain, a.fly_gain, b.fly_gain) |*w, x, y| {
            w.* = @max(0, (if (rng.boolean()) x else y) + mutation(rng, rate, 0.1));
        }
        return g;
    }

    pub fn deinit(g: Genome, gpa: std.mem.Allocator) void {
        gpa.free(g.fly_gain);
    }

    /// Cognitive network forward pass; updates activations & eligibility traces.
    pub fn decide(g: *Genome, in: [social_inputs]f32) SocialAction {
        return g.cog.decide(in);
    }
};

const motor_defaults = [motor_count]f32{ 400.0, 1.5, 0.25, 0.8, 1.0 };
const motor_spread = [motor_count]f32{ 0.5, 0.4, 0.3, 0.4, 0.3 };

fn mutation(rng: Random, rate: f32, size: f32) f32 {
    return if (rng.float(f32) < rate) rng.floatNorm(f32) * size else 0;
}
