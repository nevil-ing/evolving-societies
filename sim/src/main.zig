const std = @import("std");
const rl = @import("raylib");
const ui = @import("ui.zig");
const life_view = @import("life_view.zig");

const usage =
    \\usage: evolving-societies [--seed N] [--shot FILE [SECONDS [ZOOM]]]
    \\  --seed N      world seed (random if omitted)
    \\  --shot FILE   simulate SECONDS (default 90), save a screenshot, exit
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var opts: ui.Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--seed") and i + 1 < args.len) {
            i += 1;
            opts.seed = try std.fmt.parseInt(u64, args[i], 10);
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

    rl.SetConfigFlags(@intCast(rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_MSAA_4X_HINT | rl.FLAG_VSYNC_HINT | rl.FLAG_WINDOW_HIGHDPI));
    rl.InitWindow(1440, 900, "Evolving Societies");
    defer rl.CloseWindow();
    ui.initFont();
    defer ui.deinitFont();
    rl.SetTargetFPS(60);
    rl.SetExitKey(0);

    try life_view.run(gpa, opts);
}
