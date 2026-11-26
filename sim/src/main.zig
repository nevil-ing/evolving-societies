const std = @import("std");
const rl = @import("raylib");
const fly = @import("flybrain.zig");
const sim = @import("world.zig");
const log = @import("logger.zig");
const ui = @import("ui.zig");
const life_view = @import("life_view.zig");

const usage =
    \\usage: evolving-societies [--seed N] [--out FILE] [--load FILE] [--save FILE] [--shot FILE [SECONDS [ZOOM]]] [--headless SECONDS]
    \\  --seed N            world seed (random if omitted)
    \\  --out FILE          CSV path for run telemetry (default data/world_states/run_<seed>.csv)
    \\  --load FILE         load a saved binary .esav world snapshot before running
    \\  --save FILE         save a binary .esav world snapshot after headless run
    \\  --shot FILE         simulate SECONDS (default 90), save a screenshot, exit
    \\  --headless SECONDS  run without opening a window and write CSV telemetry
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var opts: ui.Options = .{};
    var headless_secs: ?u32 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--seed") and i + 1 < args.len) {
            i += 1;
            opts.seed = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--out") and i + 1 < args.len) {
            i += 1;
            opts.out = args[i];
        } else if (std.mem.eql(u8, a, "--load") and i + 1 < args.len) {
            i += 1;
            opts.load_path = args[i];
        } else if (std.mem.eql(u8, a, "--save") and i + 1 < args.len) {
            i += 1;
            opts.save_path = args[i];
        } else if (std.mem.eql(u8, a, "--headless") and i + 1 < args.len) {
            i += 1;
            headless_secs = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--shot") and i + 1 < args.len) {
            i += 1;
            opts.shot = args[i];
            if (i + 1 < args.len and std.ascii.isDigit(args[i + 1][0])) {
                i += 1;
                opts.warmup = try std.fmt.parseInt(u32, args[i], 10);
                if (i + 1 < args.len and std.ascii.isDigit(args[i + 1][0])) {
                    i += 1;
                    opts.zoom = try std.fmt.parseFloat(f32, args[i]);
                }
            }
        } else {
            std.debug.print(usage, .{});
            return;
        }
    }

    if (headless_secs) |secs| {
        const seed = opts.seed orelse 7919;
        const circuit = try fly.Circuit.parse(gpa, @embedFile("flybrain"));
        var world = try sim.World.init(gpa, &circuit, seed);
        if (opts.load_path) |lp| try world.loadSnapshot(lp);
        var logger = log.RunLogger.init(seed, opts.out);
        defer logger.deinit();
        logger.logNow(&world);
        for (0..@as(usize, secs) * 60) |_| {
            try world.step(1.0 / 60.0);
            logger.maybeLog(&world);
        }
        logger.logNow(&world);
        if (opts.save_path) |sp| {
            try world.saveSnapshot(sp);
            std.debug.print("saved snapshot: {s}\n", .{sp});
        }
        std.debug.print("headless run complete: {d}s, seed {d}, max gen {d}, clades {d}/{d}, log: {s}\n", .{
            secs, seed, world.max_generation, world.activeCladeCount(), world.clade_count, logger.path(),
        });
        for (0..world.clade_count) |si| {
            std.debug.print("  {s:<10} pop={d:<3} births={d:<4} starved={d:<4} killed={d:<3} max_gen={d}\n", .{
                world.clades[si].name(), world.population(si), world.stats[si].births, world.stats[si].deaths[0], world.stats[si].deaths[2], world.stats[si].max_gen,
            });
        }
        return;
    }

    rl.SetConfigFlags(@intCast(rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_MSAA_4X_HINT | rl.FLAG_VSYNC_HINT | rl.FLAG_WINDOW_HIGHDPI));
    rl.InitWindow(1440, 900, "Evolving Societies");
    defer rl.CloseWindow();
    ui.initFont();
    defer ui.deinitFont();
    rl.SetTargetFPS(60);
    rl.SetExitKey(0);

    try life_view.run(gpa, opts);
}
