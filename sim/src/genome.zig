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

/// Growing, recurrent cognitive network node layout:
///   0 .. social_inputs-1                            : sensory, state, memory, acoustic ears, kinship, health, cargo & egocentric bearings
///   social_inputs .. social_inputs+max_cog_hidden-1 : evolvable leaky recurrent hidden neurons
///   out_base .. out_base+action_outputs-1           : 9 discrete action outputs (incl. unscripted offer/trade)
///   out_base+9 .. out_base+15                       : 7 continuous cortical outputs (turn, speed, mod, call_vol, call_f0..f2)
pub const social_inputs = 36;
pub const SocialAction = enum(u8) { forage, fight, mate, socialize, flee, gather, craft_tool, build, offer };
pub const action_outputs = @typeInfo(SocialAction).@"enum".field_names.len;
pub const motor_outputs = 7; // turn_out, speed_out, mod_out, call_out (vol), call_f[0..3]
pub const social_outputs = action_outputs + motor_outputs;
pub const max_cog_hidden = 24;
pub const out_base = social_inputs + max_cog_hidden;
pub const max_cog_nodes = out_base + social_outputs;
pub const max_cog_synapses = 380;

pub const Synapse = struct {
    from: u8,
    to: u8,
    weight: f32,
    innov: u32 = 0, // lightweight NEAT historical innovation tag to prevent competing-conventions crossover
    active: bool = true,

    pub fn isRecurrent(s: Synapse) bool {
        return s.from >= social_inputs and s.from < out_base and s.to >= social_inputs and s.to < out_base;
    }
};

fn computeInnov(from: u8, to: u8, parent_innov: u32) u32 {
    var h: u32 = parent_innov *% 2654435761;
    h ^= (@as(u32, from) << 8) | @as(u32, to);
    h = (h ^ (h >> 16)) *% 0x45d9f3b;
    return if (h == 0) 1 else h;
}

pub const CognitiveBrain = struct {
    hidden_count: u8 = 4,
    synapse_count: u16 = 0,
    synapses: [max_cog_synapses]Synapse = undefined,
    bias: [max_cog_hidden + social_outputs]f32 = @splat(0),
    /// Online value/outcome predictor weights (for Temporal-Difference dopamine learning).
    pred_w: [max_cog_hidden]f32 = @splat(0),
    pred_bias: f32 = 0,
    /// Evolvable ABCD Hebbian meta-learning plasticity rule (Soltoggio 2008 / Najarro & Risi 2020).
    /// `hebb_d` is an additive Soltoggio bias term; unsigned homeostatic decay is applied separately.
    hebb_a: f32 = 0.8,
    hebb_b: f32 = 0.0,
    hebb_c: f32 = 0.0,
    hebb_d: f32 = 0.0,
    hebb_lr: f32 = 0.065,
    /// Runtime activations (hidden neurons carry double-buffered leaky recurrent working memory).
    act: [max_cog_nodes]f32 = @splat(0),
    /// Decaying pre*post eligibility traces for TD + ABCD plasticity.
    elig: [max_cog_synapses]f32 = @splat(0),
    /// Continuous cortical outputs computed on every decide().
    turn_out: f32 = 0, // -1..+1 direct continuous steering torque
    speed_out: f32 = 0, // -1..+1 direct continuous speed modulation
    mod_out: f32 = 0, // -1..+1 evolved internal neuromodulatory gate
    call_out: f32 = 0, // -1..+1 neural vocalization volume/drive (> 0.55 broadcasts)
    call_f: [3]f32 = .{ 0, 0, 0 }, // -1..+1 arbitrary 3-channel acoustic vocal token (zero hardcoded meaning)
    /// Dynamic neuromodulators (runtime internal state).
    dopamine: f32 = 0.5, // reward surprise / motivation -> boosts plasticity
    noradrenaline: f32 = 0.2, // arousal / vigilance -> speeds thinking & adaptation
    serotonin: f32 = 0.5, // calm / patience -> favors long-term building & care
    prev_pred: f32 = 0,
    last_pred: f32 = 0,
    last_td_error: f32 = 0,
    /// Synapses/neurons sprouted through lifetime experience.
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

    pub fn recurrentSynapses(b: *const CognitiveBrain) u32 {
        var n: u32 = 0;
        for (b.synapses[0..b.synapse_count]) |s| {
            if (s.active and s.isRecurrent()) n += 1;
        }
        return n;
    }

    pub fn random(rng: Random) CognitiveBrain {
        var b = CognitiveBrain{
            .hidden_count = 4,
            .hebb_a = std.math.clamp(0.8 + rng.floatNorm(f32) * 0.25, -1.5, 1.5),
            .hebb_b = std.math.clamp(rng.floatNorm(f32) * 0.12, -0.8, 0.8),
            .hebb_c = std.math.clamp(rng.floatNorm(f32) * 0.12, -0.8, 0.8),
            .hebb_d = std.math.clamp(rng.floatNorm(f32) * 0.02, -0.15, 0.15),
            .hebb_lr = std.math.clamp(0.065 + rng.floatNorm(f32) * 0.02, 0.005, 0.15),
        };
        for (&b.bias) |*v| v.* = rng.floatNorm(f32) * 0.25;
        for (0..b.hidden_count) |hi| b.pred_w[hi] = rng.floatNorm(f32) * 0.2;
        // Founders lean toward foraging; curious individuals discover tools, building,
        // territorial defense, and continuous cortical steering through evolution & ABCD plasticity.
        b.bias[max_cog_hidden + @backingInt(SocialAction.forage)] += 1.35;
        b.bias[max_cog_hidden + @backingInt(SocialAction.gather)] += 0.15;
        b.bias[max_cog_hidden + @backingInt(SocialAction.craft_tool)] += 0.10;
        b.bias[max_cog_hidden + @backingInt(SocialAction.build)] += 0.10;
        // Keep initial cortical turn/speed biases near zero so Gen 1 founders inherit clean FlyWire steering,
        // quiet initial vocalization threshold, and diverse starter voice timbres across [-0.8, +0.8]^3.
        b.bias[max_cog_hidden + action_outputs + 0] = 0;
        b.bias[max_cog_hidden + action_outputs + 1] = 0;
        b.bias[max_cog_hidden + action_outputs + 3] = -0.50;
        for (0..3) |fi| {
            b.bias[max_cog_hidden + action_outputs + 4 + fi] = (rng.float(f32) * 2.0 - 1.0) * 0.85;
        }

        // Compact starter wiring: sparse input -> hidden, hidden -> output, and 2 starter recurrent memory loops.
        for (0..b.hidden_count) |hi| {
            const h_node: u8 = @intCast(social_inputs + hi);
            for (0..social_inputs) |ii| {
                if (rng.float(f32) < 0.32) {
                    _ = b.insertSynapse(@intCast(ii), h_node, rng.floatNorm(f32) * 0.50);
                }
            }
            for (0..social_outputs) |oi| {
                const o_node: u8 = @intCast(out_base + oi);
                const scale: f32 = if (oi >= action_outputs) 0.06 else 0.52;
                _ = b.insertSynapse(h_node, o_node, rng.floatNorm(f32) * scale);
            }
        }
        // Seed sparse random zero-mean direct sensorimotor & acoustic synapses (no hardcoded sign or meaning!)
        // so 3-factor ABCD Hebbian plasticity & evolution can rapidly tune steering, speed, and dialects.
        const turn_node: u8 = @intCast(out_base + action_outputs + 0);
        const speed_node: u8 = @intCast(out_base + action_outputs + 1);
        const call_node: u8 = @intCast(out_base + action_outputs + 3);
        for ([_]u8{ 20, 21, 22, 23, 24, 25, 30 }) |ii| {
            _ = b.insertSynapse(ii, turn_node, rng.floatNorm(f32) * 0.10);
        }
        for ([_]u8{ 0, 3, 8, 15, 18, 26, 31, 32 }) |ii| {
            _ = b.insertSynapse(ii, speed_node, rng.floatNorm(f32) * 0.10);
            _ = b.insertSynapse(ii, call_node, rng.floatNorm(f32) * 0.12);
        }
        // Kinship & trust direct pathways to turn/social actions (zero-mean starter weights).
        for ([_]u8{ 31, 32 }) |ii| {
            _ = b.insertSynapse(ii, turn_node, rng.floatNorm(f32) * 0.08);
        }
        // Context -> 3 vocal formants & heard formants -> motor outputs (purely random zero-mean starter wiring).
        for (0..3) |fi| {
            const vf_node: u8 = @intCast(out_base + action_outputs + 4 + fi);
            for ([_]u8{ 0, 3, 8, 10, 15, 18 }) |ii| {
                _ = b.insertSynapse(ii, vf_node, rng.floatNorm(f32) * 0.18);
            }
            const ear_node: u8 = @intCast(27 + fi);
            _ = b.insertSynapse(ear_node, turn_node, rng.floatNorm(f32) * 0.08);
            _ = b.insertSynapse(ear_node, speed_node, rng.floatNorm(f32) * 0.08);
            _ = b.insertSynapse(ear_node, call_node, rng.floatNorm(f32) * 0.10);
        }
        // Seed initial recurrent working-memory loops between hidden neurons.
        for (0..2) |_| {
            const h1: u8 = @intCast(social_inputs + rng.uintLessThan(usize, b.hidden_count));
            const h2: u8 = @intCast(social_inputs + rng.uintLessThan(usize, b.hidden_count));
            _ = b.insertSynapse(h1, h2, rng.floatNorm(f32) * 0.45);
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
            .pred_w = primary.pred_w,
            .pred_bias = std.math.clamp((a.pred_bias + b_parent.pred_bias) * 0.5 + mutation(rng, rate, 0.1), -2, 2),
            .hebb_a = std.math.clamp((a.hebb_a + b_parent.hebb_a) * 0.5 + mutation(rng, rate, 0.12), -1.5, 1.5),
            .hebb_b = std.math.clamp((a.hebb_b + b_parent.hebb_b) * 0.5 + mutation(rng, rate, 0.08), -0.8, 0.8),
            .hebb_c = std.math.clamp((a.hebb_c + b_parent.hebb_c) * 0.5 + mutation(rng, rate, 0.08), -0.8, 0.8),
            .hebb_d = std.math.clamp((a.hebb_d + b_parent.hebb_d) * 0.5 + mutation(rng, rate, 0.025), -0.3, 0.1),
            .hebb_lr = std.math.clamp((a.hebb_lr + b_parent.hebb_lr) * 0.5 + mutation(rng, rate, 0.01), 0.005, 0.15),
        };
        for (&c.bias, secondary.bias) |*bv, sv| {
            const pick = if (rng.boolean()) bv.* else sv;
            bv.* = std.math.clamp(pick + mutation(rng, rate, 0.14), -4, 4);
        }
        for (&c.pred_w, secondary.pred_w) |*pw, sw| {
            const pick = if (rng.boolean()) pw.* else sw;
            pw.* = std.math.clamp(pick + mutation(rng, rate, 0.12), -2, 2);
        }

        for (primary.synapses[0..primary.synapse_count]) |s| {
            if (!s.active) continue;
            var w = s.weight;
            // Innovation-aligned crossover (Stanley & Miikkulainen 2002) avoids competing-conventions collisions.
            if (secondary.findSynapseByInnov(s.innov) orelse secondary.findSynapse(s.from, s.to)) |other_w| {
                w = if (rng.boolean()) w else other_w;
            }
            w = std.math.clamp(w + mutation(rng, rate, 0.16), -4, 4);
            _ = c.insertSynapseInnov(s.from, s.to, w, s.innov);
        }

        // Structural evolution: synaptogenesis (including recurrent loops), neurogenesis, and pruning.
        if (rng.float(f32) < 0.26) _ = c.addRandomSynapse(rng);
        if (rng.float(f32) < 0.12) _ = c.addNeuron(rng);
        if (rng.float(f32) < 0.10) c.pruneWeak();
        return c;
    }

    pub fn findSynapse(b: *const CognitiveBrain, from: u8, to: u8) ?f32 {
        for (b.synapses[0..b.synapse_count]) |s| {
            if (s.active and s.from == from and s.to == to) return s.weight;
        }
        return null;
    }

    pub fn findSynapseByInnov(b: *const CognitiveBrain, innov: u32) ?f32 {
        if (innov == 0) return null;
        for (b.synapses[0..b.synapse_count]) |s| {
            if (s.active and s.innov == innov) return s.weight;
        }
        return null;
    }

    fn insertSynapse(b: *CognitiveBrain, from: u8, to: u8, weight: f32) bool {
        return b.insertSynapseInnov(from, to, weight, computeInnov(from, to, 0));
    }

    fn insertSynapseInnov(b: *CognitiveBrain, from: u8, to: u8, weight: f32, innov: u32) bool {
        const is_hidden_from = from >= social_inputs and from < out_base;
        const is_hidden_to = to >= social_inputs and to < out_base;
        const valid = (from < to and from < out_base and to >= social_inputs) or (is_hidden_from and is_hidden_to);
        if (!valid) return false;
        if (b.findSynapse(from, to) != null) return false;
        if (b.synapse_count >= max_cog_synapses) return false;
        b.synapses[b.synapse_count] = .{ .from = from, .to = to, .weight = weight, .innov = innov, .active = true };
        b.elig[b.synapse_count] = 0;
        b.synapse_count += 1;
        return true;
    }

    /// Synaptogenesis: connect two previously unlinked nodes (25% chance of recurrent memory loop).
    pub fn addRandomSynapse(b: *CognitiveBrain, rng: Random) bool {
        if (b.hidden_count > 0 and rng.float(f32) < 0.25) {
            for (0..8) |_| {
                const from: u8 = @intCast(social_inputs + rng.uintLessThan(usize, b.hidden_count));
                const to: u8 = @intCast(social_inputs + rng.uintLessThan(usize, b.hidden_count));
                if (b.insertSynapse(from, to, rng.floatNorm(f32) * 0.4)) return true;
            }
        }
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

    /// Neurogenesis: split any active feed-forward synapse (including input->hidden and hidden->hidden!)
    /// to grow genuine multi-layer feature hierarchies while preserving innovation lineage.
    pub fn addNeuron(b: *CognitiveBrain, rng: Random) bool {
        if (b.hidden_count >= max_cog_hidden) return false;
        if (b.synapse_count + 2 > max_cog_synapses) return false;

        var candidates: [max_cog_synapses]u16 = undefined;
        var count: usize = 0;
        for (b.synapses[0..b.synapse_count], 0..) |s, i| {
            if (s.active and s.from < s.to) {
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
        _ = b.insertSynapseInnov(old.from, new_node, 1.0, computeInnov(old.from, new_node, old.innov));
        _ = b.insertSynapseInnov(new_node, old.to, old.weight, computeInnov(new_node, old.to, old.innov));
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

    /// Recurrent leaky forward pass (deterministic, zero exploratory noise).
    pub fn decide(b: *CognitiveBrain, in: [social_inputs]f32) SocialAction {
        return b.decideExplore(in, @splat(0));
    }

    /// Recurrent leaky forward pass with LMAN-style exploratory motor babbling and
    /// Fiete-Seung node-perturbation eligibility traces for online sensorimotor learning.
    pub fn decideExplore(b: *CognitiveBrain, in: [social_inputs]f32, motor_noise: [motor_outputs]f32) SocialAction {
        var prev_h: [max_cog_hidden]f32 = @splat(0);
        for (0..b.hidden_count) |hi| prev_h[hi] = b.act[social_inputs + hi];

        for (in, 0..) |x, i| b.act[i] = x;

        var accum: [max_cog_nodes]f32 = @splat(0);
        for (0..b.hidden_count) |hi| accum[social_inputs + hi] = b.bias[hi];
        for (0..social_outputs) |oi| accum[out_base + oi] = b.bias[max_cog_hidden + oi];

        // Double-buffered leaky recurrent hidden layer: reads ALL hidden-to-hidden inputs strictly from
        // `prev_h` and writes to `next_h`, making recurrent dynamics 100% permutation-invariant.
        const leak: f32 = 0.65;
        var next_h: [max_cog_hidden]f32 = @splat(0);
        for (0..b.hidden_count) |hi| {
            const node: u8 = @intCast(social_inputs + hi);
            var sum = accum[node];
            for (b.synapses[0..b.synapse_count]) |s| {
                if (!s.active or s.to != node) continue;
                const pre = if (s.from >= social_inputs and s.from < out_base)
                    prev_h[s.from - social_inputs]
                else
                    b.act[s.from];
                sum += s.weight * pre;
            }
            next_h[hi] = (1 - leak) * prev_h[hi] + leak * std.math.tanh(sum);
        }
        for (0..b.hidden_count) |hi| b.act[social_inputs + hi] = next_h[hi];

        // Online outcome/value prediction from internal hidden state (for TD bootstrapping).
        b.prev_pred = b.last_pred;
        var pred = b.pred_bias;
        for (0..b.hidden_count) |hi| pred += b.pred_w[hi] * b.act[social_inputs + hi];
        b.last_pred = std.math.tanh(pred);

        // Evaluate discrete action logits (0..action_outputs-1) and continuous cortical outputs (turn, speed, mod, call).
        var best: usize = 0;
        var best_val: f32 = -std.math.inf(f32);
        var motor_delta: [motor_outputs]f32 = @splat(0);
        for (0..social_outputs) |oi| {
            const node: u8 = @intCast(out_base + oi);
            var sum = accum[node];
            for (b.synapses[0..b.synapse_count]) |s| {
                if (s.active and s.to == node) sum += s.weight * b.act[s.from];
            }
            if (oi < action_outputs) {
                const act_kind: SocialAction = @fromBackingInt(@intCast(oi));
                switch (act_kind) {
                    .build, .gather, .socialize => sum += 0.24 * (b.serotonin - 0.5),
                    .flee, .fight => sum += 0.24 * (b.noradrenaline - 0.5),
                    .craft_tool => sum += 0.18 * (b.dopamine - 0.5),
                    else => {},
                }
                b.act[node] = std.math.tanh(sum);
                if (sum > best_val) {
                    best_val = sum;
                    best = oi;
                }
            } else {
                const mi = oi - action_outputs;
                const mean_val = std.math.tanh(sum);
                const val = std.math.tanh(sum + motor_noise[mi]);
                motor_delta[mi] = val - mean_val;
                b.act[node] = val;
                switch (mi) {
                    0 => b.turn_out = val,
                    1 => b.speed_out = val,
                    2 => b.mod_out = val,
                    3 => b.call_out = val,
                    4 => b.call_f[0] = val,
                    5 => b.call_f[1] = val,
                    6 => b.call_f[2] = val,
                    else => {},
                }
            }
        }

        // Update decaying eligibility traces (1.7s distal reward window, Izhikevich 2007).
        // Continuous motor synapses combine node-perturbation (pre * motor_delta) with post-synaptic Hebbian
        // activity so zero-initialized synapses break symmetry and learn online from exploratory babbling.
        for (b.synapses[0..b.synapse_count], b.elig[0..b.synapse_count]) |s, *el| {
            if (!s.active) {
                el.* = 0;
                continue;
            }
            const pre = if (s.isRecurrent()) prev_h[s.from - social_inputs] else b.act[s.from];
            if (s.to >= out_base + action_outputs) {
                const mi = s.to - (out_base + action_outputs);
                const post_sig = if (motor_noise[mi] != 0)
                    0.80 * motor_delta[mi] + 0.20 * b.act[s.to]
                else
                    b.act[s.to];
                // Fast motor trace (0.45 decay, full 1.0 current weight) so 1-step sensory TD
                // cleanly credits the exact motor babble that produced the sensory change.
                el.* = 0.45 * el.* + 1.0 * pre * post_sig;
            } else {
                el.* = 0.90 * el.* + 0.10 * pre * b.act[s.to];
            }
        }

        return @fromBackingInt(@intCast(best));
    }

    /// Evolved ABCD Hebbian meta-learning modulated by TD bootstrapping dopamine AND `mod_out`.
    /// Unsigned homeostatic weight decay is separated from signed `mod_gate` so punishment never
    /// sign-inverts decay into weight runaway!
    pub fn learn(b: *CognitiveBrain, reward: f32) void {
        if (@abs(reward) < 1e-4) return;
        const pred_scale = @min(@as(f32, 0.45), @abs(reward) * 1.5);
        const td_boot = (0.90 * b.last_pred - b.prev_pred) * pred_scale;
        const td = std.math.clamp(reward + td_boot, -1.5, 1.5);
        b.last_td_error = td;
        b.pred_bias = std.math.clamp(b.pred_bias + 0.03 * td, -2, 2);
        for (0..b.hidden_count) |hi| {
            b.pred_w[hi] = std.math.clamp(b.pred_w[hi] + 0.04 * td * b.act[social_inputs + hi], -2, 2);
        }
        const mod_gate = std.math.clamp(0.72 * td + 0.28 * b.mod_out * @abs(td), -1.5, 1.5);
        const abs_gate = @abs(mod_gate);
        const lr: f32 = b.hebb_lr * (0.65 + 0.7 * b.dopamine + 0.4 * b.noradrenaline);
        for (b.synapses[0..b.synapse_count], b.elig[0..b.synapse_count]) |*s, el| {
            if (!s.active) continue;
            const pre = b.act[s.from];
            const post = b.act[s.to];
            // Soltoggio ABCD correlation + additive offset D, minus unsigned homeostatic decay!
            const hebb = b.hebb_a * el + b.hebb_b * pre + b.hebb_c * post + b.hebb_d;
            const decay = 0.012 * abs_gate * s.weight;
            const motor_boost: f32 = if (s.to >= out_base + action_outputs) 3.2 else 1.0;
            const raw_delta = lr * motor_boost * mod_gate * hebb - lr * decay;
            if (@abs(raw_delta) < 1e-7) continue;
            const delta = std.math.clamp(raw_delta, -0.25, 0.25);
            s.weight = std.math.clamp(s.weight + delta, -4, 4);
        }
        b.dopamine = std.math.clamp(b.dopamine + 0.18 * (std.math.clamp(0.5 + 0.45 * td, 0.05, 1.0) - b.dopamine), 0.05, 1.0);
    }

    /// Cultural vocal learning: gently pulls a young learner's vocal formants toward a heard elder/kin token
    /// (regional accent), and binds incoming context synapses ONLY under joint attention (`bind_context == true`).
    pub fn imitateVocal(b: *CognitiveBrain, target_f: [3]f32, rate: f32, bind_context: bool) void {
        for (0..3) |fi| {
            const bi = max_cog_hidden + action_outputs + 4 + fi;
            const err = target_f[fi] - b.call_f[fi];
            b.bias[bi] = std.math.clamp(b.bias[bi] + rate * err, -3, 3);
            if (!bind_context) continue;
            const node: u8 = @intCast(out_base + action_outputs + 4 + fi);
            for (b.synapses[0..b.synapse_count]) |*s| {
                if (s.active and s.to == node) {
                    s.weight = std.math.clamp(s.weight + rate * 0.35 * err * b.act[s.from], -4, 4);
                }
            }
        }
    }

    /// Cultural observational imitation: when a juvenile witnesses a skilled elder succeed at crafting,
    /// building, or hunting, gently bias its cortical action circuits toward that observed behavior.
    pub fn imitateAction(b: *CognitiveBrain, action: SocialAction, rate: f32) void {
        const ai = @backingInt(action);
        const bi = max_cog_hidden + ai;
        b.bias[bi] = std.math.clamp(b.bias[bi] + rate, -3, 3);
        const node: u8 = @intCast(out_base + ai);
        for (b.synapses[0..b.synapse_count]) |*s| {
            if (s.active and s.to == node) {
                s.weight = std.math.clamp(s.weight + rate * 0.25 * b.act[s.from], -4, 4);
            }
        }
    }

    /// Experience-driven developmental rewiring: sprouts synapses and occasionally new neurons in life!
    pub fn sproutFromExperience(b: *CognitiveBrain, rng: Random) bool {
        if (b.lifetime_rewires >= 8) return false;
        const grew = if (b.lifetime_rewires >= 3 and rng.float(f32) < 0.25)
            b.addNeuron(rng) or b.addRandomSynapse(rng)
        else
            b.addRandomSynapse(rng);
        if (grew) {
            b.lifetime_rewires += 1;
            return true;
        }
        return false;
    }
};

pub const Genome = struct {
    traits: [trait_count]f32,
    motor: [motor_count]f32,
    /// Continuous evolvable digestive specialization across (meat, plant, mineral), simplex-normalized (sum = 1).
    digest: [3]f32 = .{ 0.34, 0.33, 0.33 },
    /// Heritable continuous genetic kin/species marker vector in [0, 1]^4 for true speciation & kin recognition.
    kin_tag: [4]f32 = .{ 0.5, 0.5, 0.5, 0.5 },
    /// Wyatt (2010) 3-channel unit chemical signature mixture for O(1) unlimited-clade trail blends.
    chem_sig: [3]f32 = .{ 1, 0, 0 },
    /// Heritable adult body scale (0.80..1.25) with Kleiber allometric metabolic scaling.
    body_scale: f32 = 1.0,
    /// Innate MHC immune signature (8 polymorphic loci, alleles 0..15) driving Red Queen host-pathogen co-evolution.
    mhc: [8]u8 = .{ 1, 3, 5, 7, 9, 11, 13, 15 },
    cog: CognitiveBrain,
    fly_gain: []f32, // one per cell type in the circuit

    pub fn trait(g: *const Genome, t: Trait) f32 {
        return g.traits[@backingInt(t)];
    }
    pub fn motorGene(g: *const Genome, m: MotorGene) f32 {
        return g.motor[@backingInt(m)];
    }

    /// Innate MHC immune recognition score in [0, 1] against an 8-locus pathogen signature.
    pub fn mhcAffinity(g: *const Genome, sig: [8]u8) f32 {
        var score: f32 = 0;
        for (g.mhc, sig) |a, b| {
            const diff = if (a >= b) a - b else b - a;
            if (diff == 0) score += 1.0 else if (diff == 1) score += 0.5;
        }
        return score / 8.0;
    }

    /// Biological specialist-vs-generalist digestive yield curve for meat (0), plant (1), mineral (2).
    /// Pure specialists extract ~100% on native food; omnivores ~52% on two; generalists ~35% on all three.
    pub fn digestionYield(g: *const Genome, food_idx: usize) f32 {
        if (food_idx >= 3) return 1.0;
        const d = g.digest[food_idx];
        const adapt = g.trait(.adaptability);
        if (d < 0.14 and adapt <= 0.65) return 0;
        const raw = std.math.clamp(1.18 * std.math.pow(f32, @max(0, d), 1.10), 0, 1.0);
        return if (adapt > 0.65) @max(raw, 0.35) else raw;
    }

    pub fn geneticDist(a: *const Genome, b: *const Genome) f32 {
        return a.tagDistTo(b.kin_tag, b.digest);
    }

    pub fn geneticSim(a: *const Genome, b: *const Genome) f32 {
        return std.math.clamp(1.0 - a.geneticDist(b), 0, 1);
    }

    pub fn tagDistTo(g: *const Genome, other_tag: [4]f32, other_digest: [3]f32) f32 {
        var tsum: f32 = 0;
        for (0..4) |k| {
            const d = g.kin_tag[k] - other_tag[k];
            tsum += d * d;
        }
        var dsum: f32 = 0;
        for (0..3) |k| {
            const d = g.digest[k] - other_digest[k];
            dsum += d * d;
        }
        const t_rms = @sqrt(tsum / 4.0);
        const d_rms = @sqrt(dsum / 3.0);
        return std.math.clamp(0.70 * t_rms + 0.30 * d_rms, 0, 1);
    }

    pub fn random(gpa: std.mem.Allocator, rng: Random, cell_types: usize) !Genome {
        return randomForNiche(gpa, rng, cell_types, null, null);
    }

    pub fn randomForNiche(gpa: std.mem.Allocator, rng: Random, cell_types: usize, pref_food: ?usize, base_tag: ?[4]f32) !Genome {
        var g: Genome = undefined;
        for (&g.traits) |*t| t.* = rng.float(f32);
        g.motor = motor_defaults;
        for (&g.motor, motor_spread) |*m, s| m.* *= 1 + s * rng.floatNorm(f32);
        if (pref_food) |pf| {
            g.digest = .{ 0.08, 0.08, 0.08 };
            if (pf < 3) g.digest[pf] = 0.84;
            for (&g.digest) |*dv| dv.* = @max(0.02, dv.* + rng.floatNorm(f32) * 0.04);
        } else {
            for (&g.digest) |*dv| dv.* = 0.05 + rng.float(f32);
        }
        normalizeDigest(&g.digest);
        if (base_tag) |bt| {
            for (&g.kin_tag, bt) |*kt, bv| kt.* = std.math.clamp(bv + rng.floatNorm(f32) * 0.09, 0, 1);
        } else {
            for (&g.kin_tag) |*kt| kt.* = rng.float(f32);
        }
        g.chem_sig = .{ g.kin_tag[0], g.kin_tag[1], g.kin_tag[2] };
        normalizeChem(&g.chem_sig);
        g.body_scale = std.math.clamp(1.0 + rng.floatNorm(f32) * 0.08, 0.80, 1.25);
        for (&g.mhc) |*locus| locus.* = rng.uintLessThan(u8, 16);
        g.cog = CognitiveBrain.random(rng);
        g.fly_gain = try gpa.alloc(f32, cell_types);
        for (g.fly_gain) |*w| w.* = @max(0, 1 + 0.12 * rng.floatNorm(f32));
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
        for (&g.digest, a.digest, b.digest) |*dv, x, y| {
            dv.* = @max(0.02, (x + y) * 0.5 + mutation(rng, rate * 1.4, 0.10));
        }
        normalizeDigest(&g.digest);
        const saltation = rng.float(f32) < 0.05;
        for (&g.kin_tag, a.kin_tag, b.kin_tag) |*kt, x, y| {
            const jump: f32 = if (saltation) rng.floatNorm(f32) * 0.28 else 0;
            kt.* = std.math.clamp((x + y) * 0.5 + mutation(rng, rate * 1.5, 0.12) + jump, 0, 1);
        }
        for (&g.chem_sig, a.chem_sig, b.chem_sig) |*cs, x, y| {
            cs.* = @max(0.01, (x + y) * 0.5 + mutation(rng, rate, 0.08));
        }
        normalizeChem(&g.chem_sig);
        g.body_scale = std.math.clamp((a.body_scale + b.body_scale) * 0.5 + mutation(rng, rate, 0.05), 0.80, 1.25);
        for (&g.mhc, a.mhc, b.mhc) |*locus, ma, mb| {
            var v = if (rng.boolean()) ma else mb;
            if (rng.float(f32) < 0.04) v = rng.uintLessThan(u8, 16);
            locus.* = v;
        }
        g.cog = CognitiveBrain.child(rng, &a.cog, &b.cog, rate);
        g.fly_gain = try gpa.alloc(f32, a.fly_gain.len);
        // Gentle fly_gain mutation (0.05) curbs 350-D neutral drift while preserving brainstem selection.
        for (g.fly_gain, a.fly_gain, b.fly_gain) |*w, x, y| {
            w.* = @max(0, (if (rng.boolean()) x else y) + mutation(rng, rate, 0.05));
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

    /// Forward pass with LMAN-style exploratory motor babbling on continuous outputs.
    pub fn decideExplore(g: *Genome, in: [social_inputs]f32, motor_noise: [motor_outputs]f32) SocialAction {
        return g.cog.decideExplore(in, motor_noise);
    }
};

pub fn normalizeDigest(d: *[3]f32) void {
    var sum: f32 = 0;
    for (d) |*v| {
        v.* = @max(0.02, v.*);
        sum += v.*;
    }
    if (sum > 0) {
        for (d) |*v| v.* /= sum;
    }
}

pub fn normalizeChem(c: *[3]f32) void {
    var sq: f32 = 0;
    for (c) |*v| {
        v.* = @max(0.01, v.*);
        sq += v.* * v.*;
    }
    const norm = @sqrt(sq);
    if (norm > 1e-6) {
        for (c) |*v| v.* /= norm;
    }
}

const motor_defaults = [motor_count]f32{ 400.0, 1.5, 0.25, 0.8, 1.0 };
const motor_spread = [motor_count]f32{ 0.5, 0.4, 0.3, 0.4, 0.3 };

fn mutation(rng: Random, rate: f32, size: f32) f32 {
    return if (rng.float(f32) < rate) rng.floatNorm(f32) * size else 0;
}
