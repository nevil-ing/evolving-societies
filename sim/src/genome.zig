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
///   0 .. social_inputs-1                            : sensory, state, memory & egocentric directional inputs
///   social_inputs .. social_inputs+max_cog_hidden-1 : evolvable leaky recurrent hidden neurons
///   out_base .. out_base+action_outputs-1           : 8 discrete action outputs
///   out_base+8 .. out_base+11                       : 4 continuous cortical outputs (turn, speed, neuromodulator, vocal call)
pub const social_inputs = 28;
pub const SocialAction = enum(u8) { forage, fight, mate, socialize, flee, gather, craft_tool, build };
pub const action_outputs = @typeInfo(SocialAction).@"enum".field_names.len;
pub const motor_outputs = 4; // turn_out, speed_out, mod_out, call_out
pub const social_outputs = action_outputs + motor_outputs;
pub const max_cog_hidden = 24;
pub const out_base = social_inputs + max_cog_hidden;
pub const max_cog_nodes = out_base + social_outputs;
pub const max_cog_synapses = 320;

pub const Synapse = struct {
    from: u8,
    to: u8,
    weight: f32,
    active: bool = true,

    pub fn isRecurrent(s: Synapse) bool {
        return s.from >= social_inputs and s.from < out_base and s.to >= social_inputs and s.to < out_base and s.from >= s.to;
    }
};

pub const CognitiveBrain = struct {
    hidden_count: u8 = 4,
    synapse_count: u16 = 0,
    synapses: [max_cog_synapses]Synapse = undefined,
    bias: [max_cog_hidden + social_outputs]f32 = @splat(0),
    /// Online value/outcome predictor weights (for Temporal-Difference dopamine learning).
    pred_w: [max_cog_hidden]f32 = @splat(0),
    pred_bias: f32 = 0,
    /// Evolvable ABCD Hebbian meta-learning plasticity rule (Soltoggio 2008 / Najarro & Risi 2020).
    hebb_a: f32 = 0.8,
    hebb_b: f32 = 0.0,
    hebb_c: f32 = 0.0,
    hebb_d: f32 = -0.015,
    hebb_lr: f32 = 0.065,
    /// Runtime activations (hidden neurons carry leaky recurrent working memory).
    act: [max_cog_nodes]f32 = @splat(0),
    /// Decaying pre*post eligibility traces for TD + ABCD plasticity.
    elig: [max_cog_synapses]f32 = @splat(0),
    /// Continuous cortical outputs computed on every decide().
    turn_out: f32 = 0, // -1..+1 direct continuous steering torque
    speed_out: f32 = 0, // -1..+1 direct continuous speed modulation
    mod_out: f32 = 0, // -1..+1 evolved internal neuromodulatory gate
    call_out: f32 = 0, // -1..+1 neural vocalization/signal drive (> 0.45 broadcasts)
    /// Dynamic neuromodulators (runtime internal state).
    dopamine: f32 = 0.5, // reward surprise / motivation -> boosts plasticity
    noradrenaline: f32 = 0.2, // arousal / vigilance -> speeds thinking & adaptation
    serotonin: f32 = 0.5, // calm / patience -> favors long-term building & care
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
            .hebb_d = std.math.clamp(-0.015 + rng.floatNorm(f32) * 0.015, -0.15, 0.05),
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
        // Keep initial cortical turn/speed biases near zero so Gen 1 founders inherit clean FlyWire steering.
        b.bias[max_cog_hidden + action_outputs + 0] = 0;
        b.bias[max_cog_hidden + action_outputs + 1] = 0;
        b.bias[max_cog_hidden + action_outputs + 3] = -0.2;

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
        // Seed sparse random zero-mean direct sensorimotor synapses (no hardcoded sign!) so
        // 3-factor ABCD Hebbian plasticity & evolution can rapidly tune steering, speed, and calling.
        const turn_node: u8 = @intCast(out_base + action_outputs + 0);
        const speed_node: u8 = @intCast(out_base + action_outputs + 1);
        const call_node: u8 = @intCast(out_base + action_outputs + 3);
        for (20..social_inputs) |ii| {
            _ = b.insertSynapse(@intCast(ii), turn_node, rng.floatNorm(f32) * 0.10);
        }
        for ([_]u8{ 0, 3, 8, 15, 18, 26 }) |ii| {
            _ = b.insertSynapse(ii, speed_node, rng.floatNorm(f32) * 0.10);
            _ = b.insertSynapse(ii, call_node, rng.floatNorm(f32) * 0.12);
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
            if (secondary.findSynapse(s.from, s.to)) |other_w| {
                w = if (rng.boolean()) w else other_w;
            }
            w = std.math.clamp(w + mutation(rng, rate, 0.16), -4, 4);
            _ = c.insertSynapse(s.from, s.to, w);
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

    fn insertSynapse(b: *CognitiveBrain, from: u8, to: u8, weight: f32) bool {
        const is_hidden_from = from >= social_inputs and from < out_base;
        const is_hidden_to = to >= social_inputs and to < out_base;
        const valid = (from < to and from < out_base and to >= social_inputs) or (is_hidden_from and is_hidden_to);
        if (!valid) return false;
        if (b.findSynapse(from, to) != null) return false;
        if (b.synapse_count >= max_cog_synapses) return false;
        b.synapses[b.synapse_count] = .{ .from = from, .to = to, .weight = weight, .active = true };
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

    /// Recurrent leaky forward pass (deterministic, zero exploratory noise).
    pub fn decide(b: *CognitiveBrain, in: [social_inputs]f32) SocialAction {
        return b.decideExplore(in, .{ 0, 0, 0, 0 });
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

        // Leaky recurrent hidden layer: blends prior working memory with new feed-forward & recurrent inputs.
        const leak: f32 = 0.65;
        for (0..b.hidden_count) |hi| {
            const node: u8 = @intCast(social_inputs + hi);
            var sum = accum[node];
            for (b.synapses[0..b.synapse_count]) |s| {
                if (!s.active or s.to != node) continue;
                const pre = if (s.from >= node and s.from < out_base)
                    prev_h[s.from - social_inputs]
                else
                    b.act[s.from];
                sum += s.weight * pre;
            }
            b.act[node] = (1 - leak) * prev_h[hi] + leak * std.math.tanh(sum);
        }

        // Online outcome/value prediction from internal hidden state.
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

    /// Evolved ABCD Hebbian meta-learning modulated by TD dopamine AND the brain's own evolved mod_out neuron.
    pub fn learn(b: *CognitiveBrain, reward: f32) void {
        if (@abs(reward) < 1e-4) return;
        const pred_scale = @min(@as(f32, 1.0), @abs(reward) * 2.5);
        const td = std.math.clamp(reward - 0.25 * b.last_pred * pred_scale, -1.5, 1.5);
        b.last_td_error = td;
        b.pred_bias = std.math.clamp(b.pred_bias + 0.03 * td, -2, 2);
        for (0..b.hidden_count) |hi| {
            b.pred_w[hi] = std.math.clamp(b.pred_w[hi] + 0.04 * td * b.act[social_inputs + hi], -2, 2);
        }
        const mod_gate = std.math.clamp(0.72 * td + 0.28 * b.mod_out * @abs(td), -1.5, 1.5);
        const lr: f32 = b.hebb_lr * (0.65 + 0.7 * b.dopamine + 0.4 * b.noradrenaline);
        for (b.synapses[0..b.synapse_count], b.elig[0..b.synapse_count]) |*s, el| {
            if (!s.active) continue;
            const pre = b.act[s.from];
            const post = b.act[s.to];
            const hebb = b.hebb_a * el + b.hebb_b * pre + b.hebb_c * post + b.hebb_d * s.weight;
            if (@abs(hebb) < 1e-6) continue;
            const motor_boost: f32 = if (s.to >= out_base + action_outputs) 3.2 else 1.0;
            const delta = std.math.clamp(lr * motor_boost * mod_gate * hebb, -0.25, 0.25);
            s.weight = std.math.clamp(s.weight + delta, -4, 4);
        }
        b.dopamine = std.math.clamp(b.dopamine + 0.18 * (std.math.clamp(0.5 + 0.45 * td, 0.05, 1.0) - b.dopamine), 0.05, 1.0);
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

    /// Forward pass with LMAN-style exploratory motor babbling on continuous outputs.
    pub fn decideExplore(g: *Genome, in: [social_inputs]f32, motor_noise: [motor_outputs]f32) SocialAction {
        return g.cog.decideExplore(in, motor_noise);
    }
};

const motor_defaults = [motor_count]f32{ 400.0, 1.5, 0.25, 0.8, 1.0 };
const motor_spread = [motor_count]f32{ 0.5, 0.4, 0.3, 0.4, 0.3 };

fn mutation(rng: Random, rate: f32, size: f32) f32 {
    return if (rng.float(f32) < rate) rng.floatNorm(f32) * size else 0;
}
