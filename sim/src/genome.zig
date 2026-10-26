//! Heritable material: body traits, fly-circuit cell-type gains, motor
//! gains, and the weights of the small social-decision network.

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

/// Social network: inputs -> hidden (tanh) -> action logits.
pub const social_inputs = 12;
pub const social_hidden = 10;
pub const SocialAction = enum(u8) { forage, fight, mate, socialize, flee };
pub const social_outputs = @typeInfo(SocialAction).@"enum".field_names.len;
pub const social_weights = social_hidden * (social_inputs + 1) + social_outputs * (social_hidden + 1);

pub const Genome = struct {
    traits: [trait_count]f32,
    motor: [motor_count]f32,
    social: [social_weights]f32,
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
        for (&g.social) |*w| w.* = rng.floatNorm(f32) * 0.6;
        // Founders lean toward foraging; evolution can find other strategies.
        g.social[social_hidden * (social_inputs + 1)] += 1.5;
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
        for (&g.social, a.social, b.social) |*w, x, y| {
            w.* = (if (rng.boolean()) x else y) + mutation(rng, rate, 0.15);
        }
        g.fly_gain = try gpa.alloc(f32, a.fly_gain.len);
        for (g.fly_gain, a.fly_gain, b.fly_gain) |*w, x, y| {
            w.* = @max(0, (if (rng.boolean()) x else y) + mutation(rng, rate, 0.1));
        }
        return g;
    }

    pub fn deinit(g: Genome, gpa: std.mem.Allocator) void {
        gpa.free(g.fly_gain);
    }

    /// Social network forward pass; returns the chosen action.
    pub fn decide(g: *const Genome, in: [social_inputs]f32) SocialAction {
        var hidden: [social_hidden]f32 = undefined;
        var k: usize = 0;
        for (&hidden) |*h| {
            var sum = g.social[k];
            k += 1;
            for (in) |x| {
                sum += g.social[k] * x;
                k += 1;
            }
            h.* = std.math.tanh(sum);
        }
        var best: usize = 0;
        var best_val: f32 = -std.math.inf(f32);
        for (0..social_outputs) |o| {
            var sum = g.social[k];
            k += 1;
            for (hidden) |h| {
                sum += g.social[k] * h;
                k += 1;
            }
            if (sum > best_val) {
                best_val = sum;
                best = o;
            }
        }
        return @fromBackingInt(@intCast(best));
    }
};

const motor_defaults = [motor_count]f32{ 400.0, 1.5, 0.25, 0.8, 1.0 };
const motor_spread = [motor_count]f32{ 0.5, 0.4, 0.3, 0.4, 0.3 };

fn mutation(rng: Random, rate: f32, size: f32) f32 {
    return if (rng.float(f32) < rate) rng.floatNorm(f32) * size else 0;
}
