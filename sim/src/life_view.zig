//! Interactive 2D view: societies, chemical overlays, HUD, key/legend, and
//! live fly-brain inspector.

const std = @import("std");
const rl = @import("raylib");
const fly = @import("flybrain.zig");
const gen = @import("genome.zig");
const sim = @import("world.zig");
const log = @import("logger.zig");
const ui = @import("ui.zig");

const World = sim.World;
const text = ui.text;
const panel = ui.panel;
const bar = ui.bar;
const bar2 = ui.bar2;
const rgb = ui.rgb;
const withAlpha = ui.withAlpha;
const rect = ui.rect;
const newSeed = ui.newSeed;

const Overlay = enum { trails, scent, off };
const speeds = [_]u32{ 1, 2, 4, 8, 16 };

const App = struct {
    world: World,
    logger: log.RunLogger,
    camera: rl.Camera2D,
    paused: bool = false,
    speed: usize = 0,
    overlay: Overlay = .trails,
    selected: ?u32 = null,
    follow: bool = false,
    show_brain: bool = true,
    show_key: bool = true,
    show_gens: bool = false,
    field_tex: rl.Texture2D,
    field_px: []u8,
};

pub fn run(gpa: std.mem.Allocator, opts: ui.Options) !void {
    const circuit = try fly.Circuit.parse(gpa, @embedFile("flybrain"));
    const shot = opts.shot;
    const warmup = opts.warmup;
    const shot_zoom = opts.zoom orelse 1.6;

    const seed = opts.seed orelse newSeed();
    var app = App{
        .world = try World.init(gpa, &circuit, seed),
        .logger = if (shot == null) log.RunLogger.init(seed, opts.out) else .{},
        .camera = .{ .offset = .{ .x = 0, .y = 0 }, .target = .{ .x = 0, .y = 0 }, .rotation = 0, .zoom = 1 },
        .field_tex = undefined,
        .field_px = undefined,
    };
    defer app.logger.deinit();
    app.logger.logNow(&app.world);
    fitCamera(&app.camera);
    const f = &app.world.field;
    app.field_px = try gpa.alloc(u8, f.cols * f.rows * 4);
    const img = rl.GenImageColor(@intCast(f.cols), @intCast(f.rows), .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    app.field_tex = rl.LoadTextureFromImage(img);
    rl.UnloadImage(img);
    rl.SetTextureFilter(app.field_tex, rl.TEXTURE_FILTER_BILINEAR);

    if (shot != null) {
        for (0..warmup * 60) |_| try app.world.step(1.0 / 60.0);
        for (app.world.entities.items) |e| if (e.dead == null and e.feeding) {
            app.selected = e.id;
        };
        if (app.selected == null and app.world.entities.items.len > 0) app.selected = app.world.entities.items[0].id;
        app.follow = true;
        app.camera.zoom = shot_zoom;
    }
    var frames: u32 = 0;

    while (!rl.WindowShouldClose()) {
        frames += 1;
        ui.beginFrame();
        if (shot) |path| if (frames == 30) {
            ui.takeScreenshot(path);
            break;
        };
        try input(&app);
        if (!app.paused) {
            for (0..speeds[app.speed]) |_| {
                try app.world.step(1.0 / 60.0);
                app.logger.maybeLog(&app.world);
            }
        }
        if (app.selected) |id| {
            if (app.world.findById(id)) |e| {
                if (app.follow) app.camera.target = .{ .x = e.pos.x, .y = e.pos.y };
            } else app.selected = null;
        }
        if (rl.IsWindowResized()) clampCamera(&app.camera);

        rl.BeginDrawing();
        rl.ClearBackground(rgb(10, 11, 18));
        app.camera.offset = cameraOffset();
        ui.beginMode2D(app.camera);
        drawWorld(&app);
        rl.EndMode2D();
        try drawHud(&app);
        rl.EndDrawing();
    }
}

// ---------------------------------------------------------------- camera

const max_zoom: f32 = 5.0;

fn fitZoom() f32 {
    const sw = ui.screenW();
    const sh = ui.screenH();
    const avail_w = @max(sw - 640, sw * 0.62);
    const avail_h = @max(sh - 104, sh * 0.78);
    return @min(avail_w / sim.bounds.w, avail_h / sim.bounds.h);
}

fn cameraOffset() rl.Vector2 {
    return .{ .x = ui.screenW() / 2, .y = (ui.screenH() - 56) / 2 };
}

fn fitCamera(cam: *rl.Camera2D) void {
    cam.offset = cameraOffset();
    const c = sim.bounds.center();
    cam.target = .{ .x = c.x, .y = c.y };
    cam.zoom = fitZoom();
}

fn clampCamera(cam: *rl.Camera2D) void {
    const fz = fitZoom();
    cam.zoom = std.math.clamp(cam.zoom, fz * 0.92, max_zoom);
    cam.offset = cameraOffset();

    const half_view_w = ui.screenW() * 0.5 / cam.zoom;
    const half_view_h = (ui.screenH() - 56) * 0.5 / cam.zoom;
    const half_world_w = sim.bounds.w * 0.5;
    const half_world_h = sim.bounds.h * 0.5;
    const c = sim.bounds.center();

    // Smoothly center as zoom approaches fit; allow panning edges clear of HUD when zoomed in.
    const zoom_in = std.math.clamp((cam.zoom - fz) / (fz * 0.5), 0, 1);
    const pad_x = 320 * zoom_in / cam.zoom;
    const pad_y = 60 * zoom_in / cam.zoom;
    const max_dx = @max(0, half_world_w + pad_x - half_view_w);
    const max_dy = @max(0, half_world_h + pad_y - half_view_h);
    cam.target.x = std.math.clamp(cam.target.x, c.x - max_dx, c.x + max_dx);
    cam.target.y = std.math.clamp(cam.target.y, c.y - max_dy, c.y + max_dy);
}

fn zoomBy(cam: *rl.Camera2D, factor: f32, anchor: ?rl.Vector2) void {
    const fz = fitZoom();
    const target_zoom = std.math.clamp(cam.zoom * factor, fz * 0.92, max_zoom);
    if (anchor) |a| {
        const before = rl.GetScreenToWorld2D(a, cam.*);
        cam.zoom = target_zoom;
        const after = rl.GetScreenToWorld2D(a, cam.*);
        cam.target.x += before.x - after.x;
        cam.target.y += before.y - after.y;
    } else {
        cam.zoom = target_zoom;
    }
    clampCamera(cam);
}

// ---------------------------------------------------------------- input

fn input(app: *App) !void {
    const cam = &app.camera;
    const pan = 600 / cam.zoom * rl.GetFrameTime();
    var panned = false;
    if (rl.IsKeyDown(rl.KEY_W) or rl.IsKeyDown(rl.KEY_UP)) {
        cam.target.y -= pan;
        panned = true;
    }
    if (rl.IsKeyDown(rl.KEY_S) or rl.IsKeyDown(rl.KEY_DOWN)) {
        cam.target.y += pan;
        panned = true;
    }
    if (rl.IsKeyDown(rl.KEY_A) or rl.IsKeyDown(rl.KEY_LEFT)) {
        cam.target.x -= pan;
        panned = true;
    }
    if (rl.IsKeyDown(rl.KEY_D) or rl.IsKeyDown(rl.KEY_RIGHT)) {
        cam.target.x += pan;
        panned = true;
    }
    if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_RIGHT) or rl.IsMouseButtonDown(rl.MOUSE_BUTTON_MIDDLE)) {
        const d = rl.GetMouseDelta();
        cam.target.x -= d.x / cam.zoom;
        cam.target.y -= d.y / cam.zoom;
        panned = true;
    }
    if (panned) {
        app.follow = false;
        clampCamera(cam);
    }

    const raw_wheel = rl.GetMouseWheelMove();
    if (raw_wheel != 0 and !ui.mouseOverPanel()) {
        const wheel = std.math.clamp(raw_wheel, -1.5, 1.5);
        zoomBy(cam, @exp(wheel * 0.08), rl.GetMousePosition());
    }

    if (rl.IsKeyPressed(rl.KEY_LEFT_BRACKET)) zoomBy(cam, 1.0 / 1.25, null);
    if (rl.IsKeyPressed(rl.KEY_RIGHT_BRACKET)) zoomBy(cam, 1.25, null);
    if (rl.IsKeyPressed(rl.KEY_ZERO)) {
        app.follow = false;
        fitCamera(cam);
    }

    if (rl.IsKeyPressed(rl.KEY_SPACE)) app.paused = !app.paused;
    if (rl.IsKeyPressed(rl.KEY_EQUAL) or rl.IsKeyPressed(rl.KEY_KP_ADD)) app.speed = @min(app.speed + 1, speeds.len - 1);
    if (rl.IsKeyPressed(rl.KEY_MINUS) or rl.IsKeyPressed(rl.KEY_KP_SUBTRACT)) app.speed -|= 1;
    if (rl.IsKeyPressed(rl.KEY_F)) cycleFood(app);
    if (rl.IsKeyPressed(rl.KEY_P)) cycleOverlay(app);
    if (rl.IsKeyPressed(rl.KEY_B)) app.show_brain = !app.show_brain;
    if (rl.IsKeyPressed(rl.KEY_L)) app.show_key = !app.show_key;
    if (rl.IsKeyPressed(rl.KEY_G)) app.show_gens = !app.show_gens;
    if (rl.IsKeyPressed(rl.KEY_C)) app.follow = !app.follow and app.selected != null;
    if (rl.IsKeyPressed(rl.KEY_R)) try restart(app);
    if (rl.IsKeyPressed(rl.KEY_ESCAPE)) {
        app.selected = null;
        app.follow = false;
    }

    if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
        const mouse = rl.GetMousePosition();
        if (try clickButtons(app, mouse)) return;
        if (ui.mouseOverPanel()) return;
        const p = rl.GetScreenToWorld2D(mouse, cam.*);
        var best: f32 = 14 / @min(cam.zoom, 1);
        app.selected = null;
        for (app.world.entities.items) |e| {
            if (e.dead != null) continue;
            const d = e.pos.dist(.{ .x = p.x, .y = p.y });
            if (d < best) {
                best = d;
                app.selected = e.id;
            }
        }
    }
}

fn cycleFood(app: *App) void {
    const n = @typeInfo(sim.Scarcity).@"enum".field_names.len;
    app.world.scarcity = @fromBackingInt(@intCast((@backingInt(app.world.scarcity) + 1) % n));
}

fn cycleOverlay(app: *App) void {
    app.overlay = @fromBackingInt(@intCast((@backingInt(app.overlay) + 1) % 3));
}

fn restart(app: *App) !void {
    const seed = newSeed();
    try app.world.reset(seed);
    app.logger.deinit();
    app.logger = log.RunLogger.init(seed, null);
    app.logger.logNow(&app.world);
    app.selected = null;
    app.follow = false;
}

const Button = enum { pause, speed, food, overlay, restart };

fn buttonRects() [5]rl.Rectangle {
    const y: f32 = @as(f32, @floatFromInt(rl.GetScreenHeight())) - 44;
    var out: [5]rl.Rectangle = undefined;
    for (&out, 0..) |*r, i| r.* = .{ .x = 16 + @as(f32, @floatFromInt(i)) * 126, .y = y, .width = 120, .height = 30 };
    return out;
}

fn clickButtons(app: *App, mouse: rl.Vector2) !bool {
    for (buttonRects(), 0..) |r, i| {
        if (!rl.CheckCollisionPointRec(mouse, r)) continue;
        switch (@as(Button, @fromBackingInt(@intCast(i)))) {
            .pause => app.paused = !app.paused,
            .speed => app.speed = (app.speed + 1) % speeds.len,
            .food => cycleFood(app),
            .overlay => cycleOverlay(app),
            .restart => try restart(app),
        }
        return true;
    }
    return false;
}

// ---------------------------------------------------------------- world

fn drawWorld(app: *App) void {
    const w = &app.world;
    const zoom = app.camera.zoom;

    const b = sim.bounds;
    const bg_col: rl.Color = switch (w.phase) {
        .calm => rgb(16, 18, 28),
        .bloom => rgb(16, 24, 26),
        .storm => rgb(13, 16, 30),
    };
    rl.DrawRectangleRec(rect(b.x, b.y, b.w, b.h), bg_col);
    // Subtle coordinate grid so movement & travel across the frontier feel tangible.
    const grid_col = withAlpha(rgb(255, 255, 255), 8);
    var gx = b.x + 200;
    while (gx < b.x + b.w) : (gx += 200) {
        rl.DrawLineEx(.{ .x = gx, .y = b.y }, .{ .x = gx, .y = b.y + b.h }, 1 / zoom, grid_col);
    }
    var gy = b.y + 200;
    while (gy < b.y + b.h) : (gy += 200) {
        rl.DrawLineEx(.{ .x = b.x, .y = gy }, .{ .x = b.x + b.w, .y = gy }, 1 / zoom, grid_col);
    }
    for (sim.societies) |s| {
        const t = s.territory;
        const col = societyColor(s);
        rl.DrawRectangleRec(rect(t.x, t.y, t.w, t.h), withAlpha(col, 18));
        rl.DrawRectangleLinesEx(rect(t.x, t.y, t.w, t.h), 2 / zoom, withAlpha(col, 90));
        text(t.x + 10, t.y + 10, 28, withAlpha(col, 150), "{s}", .{s.name});
        text(t.x + 10, t.y + 42, 16, withAlpha(rgb(200, 200, 210), 120), "{s}", .{s.environment});
    }

    if (app.overlay != .off) {
        paintField(app);
        const src = rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(w.field.cols), .height = @floatFromInt(w.field.rows) };
        const dst = rect(w.field.origin_x, w.field.origin_y, @as(f32, @floatFromInt(w.field.cols)) * w.field.cell, @as(f32, @floatFromInt(w.field.rows)) * w.field.cell);
        rl.DrawTexturePro(app.field_tex, src, dst, .{ .x = 0, .y = 0 }, 0, rgb(255, 255, 255));
    }

    for (w.resources.items) |r| {
        if (r.amount <= 0) continue;
        const radius = 2 + 3 * @sqrt(@min(r.amount, 40) / 40);
        const col = if (r.patch == null) rgb(150, 40, 40) else foodColor(r.food);
        rl.DrawCircleV(v2(r.pos), radius, col);
    }

    const selected = if (app.selected) |id| w.findById(id) else null;
    for (w.entities.items) |*e| {
        if (e.dead != null) continue;
        if (w.phase == .storm and e.huddled) {
            rl.DrawCircleV(v2(e.pos), e.radius() + 6, withAlpha(rgb(155, 195, 255), 32));
        }
        drawEntity(e, zoom, selected == e);
    }

    for (w.contacts[0..w.contact_count]) |ev| {
        const t = std.math.clamp(ev.age / sim.contact_duration, 0, 1);
        const alpha: u8 = @intFromFloat((1 - t) * 210);
        const col: rl.Color = switch (ev.kind) {
            .kin_greet => societyColor(sim.societies[ev.society]),
            .share_food => rgb(110, 245, 160),
            .rival_clash => rgb(255, 85, 65),
            .startle => rgb(255, 225, 90),
            .courtship => rgb(255, 130, 225),
        };
        const r = 5 + 14 * t;
        rl.DrawCircleLinesV(v2(ev.pos), r, withAlpha(col, alpha));
        if (ev.kind == .share_food or ev.kind == .rival_clash) {
            rl.DrawCircleLinesV(v2(ev.pos), r * 0.6, withAlpha(col, alpha / 2));
        }
    }

    if (w.phase == .storm) {
        // Subtle drifting wind streaks across the world during storm waves.
        const streak_col = withAlpha(rgb(155, 195, 255), 42);
        const shift = @mod(w.time * 240, b.w);
        for (0..36) |k| {
            const kf: f32 = @floatFromInt(k);
            const sx = b.x + @mod(kf * 197.3 + shift, b.w);
            const sy = b.y + @mod(kf * 311.7 + w.time * 45, b.h);
            rl.DrawLineEx(.{ .x = sx, .y = sy }, .{ .x = sx + 38, .y = sy + 12 }, 1.2 / zoom, streak_col);
        }
    }

    if (selected) |e| {
        const ant = [2]f32{ e.heading - 0.5, e.heading + 0.5 };
        for (ant) |a| rl.DrawLineEx(v2(e.pos), .{ .x = e.pos.x + 12 * @cos(a), .y = e.pos.y + 12 * @sin(a) }, 1.5 / zoom, rgb(230, 230, 240));
        rl.DrawCircleLinesV(v2(e.pos), 16, rgb(255, 230, 80));
        rl.DrawCircleLinesV(v2(e.pos), 160, withAlpha(rgb(255, 230, 80), 40));
        const target: ?sim.Vec2 = switch (e.action) {
            .fight => if (e.enemy) |o| w.entities.items[o].pos else null,
            .mate => if (e.mate) |o| w.entities.items[o].pos else null,
            .socialize => if (e.ally) |o| w.entities.items[o].pos else null,
            else => null,
        };
        if (target) |t| {
            rl.DrawLineEx(v2(e.pos), v2(t), 1.5 / zoom, withAlpha(actionColor(e.action), 160));
        } else if (e.explore_target) |goal| {
            rl.DrawLineEx(v2(e.pos), v2(goal), 1.2 / zoom, withAlpha(rgb(95, 220, 210), 110));
            rl.DrawCircleLinesV(v2(goal), 8 / @max(zoom, 0.4), withAlpha(rgb(95, 220, 210), 170));
        }
    }
}

fn drawEntity(e: *const sim.Entity, zoom: f32, selected: bool) void {
    const s = sim.societies[e.society];
    const size = e.radius();
    const health = std.math.clamp(e.energy / 100, 0.25, 1);
    var col = societyColor(s);
    col.r = @intFromFloat(@as(f32, @floatFromInt(col.r)) * health);
    col.g = @intFromFloat(@as(f32, @floatFromInt(col.g)) * health);
    col.b = @intFromFloat(@as(f32, @floatFromInt(col.b)) * health);
    const deg = e.heading * 180 / std.math.pi;
    const c = v2(e.pos);
    const outline: rl.Color = if (selected) rgb(255, 230, 80) else if (e.hybrid) rgb(255, 220, 60) else if (e.action == .fight) rgb(255, 60, 60) else rgb(0, 0, 0);
    const thick = (if (selected or e.hybrid) @as(f32, 2) else 1) / @max(zoom, 0.5);
    switch (s.shape) {
        .triangle => {
            rl.DrawPoly(c, 3, size * 1.2, deg, col);
            rl.DrawPolyLinesEx(c, 3, size * 1.2, deg, thick, outline);
        },
        .circle => {
            rl.DrawCircleV(c, size, col);
            rl.DrawCircleLinesV(c, size, outline);
            rl.DrawLineEx(c, .{ .x = c.x + size * @cos(e.heading), .y = c.y + size * @sin(e.heading) }, 1.5, rgb(0, 0, 0));
        },
        .square => {
            rl.DrawPoly(c, 4, size * 1.25, deg + 45, col);
            rl.DrawPolyLinesEx(c, 4, size * 1.25, deg + 45, thick, outline);
        },
    }
    if (e.feeding) rl.DrawCircleV(.{ .x = c.x + size * @cos(e.heading), .y = c.y + size * @sin(e.heading) }, 2, rgb(255, 255, 255));
    if (zoom > 1.2) {
        rl.DrawRectangleRec(rect(c.x - 8, c.y - size - 6, 16, 2), rgb(40, 40, 40));
        rl.DrawRectangleRec(rect(c.x - 8, c.y - size - 6, 16 * std.math.clamp(e.energy / sim.max_energy, 0, 1), 2), energyColor(e.energy));
    }
}

fn paintField(app: *App) void {
    const f = &app.world.field;
    const px = app.field_px;
    for (0..f.cols * f.rows) |i| {
        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;
        switch (app.overlay) {
            .trails => {
                for (sim.societies, 0..) |s, si| {
                    const t = @min(1, f.data[sim.trailChannel(si)][i] * 0.6);
                    r += t * @as(f32, @floatFromInt(s.color[0]));
                    g += t * @as(f32, @floatFromInt(s.color[1]));
                    b += t * @as(f32, @floatFromInt(s.color[2]));
                    const a = @min(1, f.data[sim.alarmChannel(si)][i] * 0.5);
                    r += a * 255;
                    g += a * 140;
                    b += a * 40;
                }
            },
            .scent => {
                for (0..sim.food_type_count) |t| {
                    const v = @min(1, f.data[sim.scentChannel(@fromBackingInt(@intCast(t)))][i] * 3);
                    const col = foodColor(@fromBackingInt(@intCast(t)));
                    r += v * @as(f32, @floatFromInt(col.r));
                    g += v * @as(f32, @floatFromInt(col.g));
                    b += v * @as(f32, @floatFromInt(col.b));
                }
            },
            .off => {},
        }
        const m = @max(r, @max(g, b));
        px[i * 4 + 0] = @intFromFloat(@min(255, r));
        px[i * 4 + 1] = @intFromFloat(@min(255, g));
        px[i * 4 + 2] = @intFromFloat(@min(255, b));
        px[i * 4 + 3] = @intFromFloat(@min(200, m * 0.8));
    }
    rl.UpdateTexture(app.field_tex, px.ptr);
}

// ---------------------------------------------------------------- HUD

fn drawHud(app: *App) !void {
    const w = &app.world;
    const sw: f32 = @floatFromInt(rl.GetScreenWidth());
    const sh: f32 = @floatFromInt(rl.GetScreenHeight());

    // Top-left status.
    panel(12, 12, 300, 92);
    const mins: u32 = @intFromFloat(w.time / 60);
    const secs: u32 = @intFromFloat(@mod(w.time, 60));
    var total: u32 = 0;
    for (0..sim.society_count) |s| total += w.population(s);
    text(24, 20, 22, rgb(235, 235, 245), "{d}:{d:0>2}", .{ mins, secs });
    text(104, 25, 13, rgb(170, 175, 190), "{s} x{d}", .{ if (app.paused) "PAUSED" else "running", speeds[app.speed] });
    drawPhaseBadge(234, 24, w.phase);
    text(24, 50, 14, rgb(200, 200, 215), "Population {d}   Max generation {d}", .{ total, w.max_generation });
    text(24, 70, 14, rgb(200, 200, 215), "Food: {s}   Overlay: {s}", .{ @tagName(w.scarcity), @tagName(app.overlay) });

    // Top-center civilization alert / updates bar (click or press G for full log & generations).
    drawAlertBar(app, sw);

    // Society panel + history chart.
    const px = sw - 312;
    panel(px, 12, 300, 300);
    var y: f32 = 22;
    for (sim.societies, 0..) |s, si| {
        var energy: f32 = 0;
        var genr: f32 = 0;
        var hybrids: u32 = 0;
        var traits: [gen.trait_count]f32 = @splat(0);
        var n: f32 = 0;
        for (w.entities.items) |e| {
            if (e.dead != null or e.society != si) continue;
            n += 1;
            energy += e.energy;
            genr += @floatFromInt(e.generation);
            if (e.hybrid) hybrids += 1;
            for (&traits, e.genome.traits) |*t, v| t.* += v;
        }
        const d = @max(n, 1);
        const st = w.stats[si];
        text(px + 12, y, 18, societyColor(s), "{s}", .{s.name});
        drawStatusBadge(px + 102, y + 3, st.status);
        text(px + 194, y + 3, 13, rgb(220, 220, 230), "pop {d:.0}  hyb {d}", .{ n, hybrids });
        text(px + 12, y + 22, 12, rgb(170, 175, 190), "births {d}  starved {d}  old {d}  killed {d}", .{ st.births, st.deaths[0], st.deaths[1], st.deaths[2] });
        text(px + 12, y + 38, 12, rgb(170, 175, 190), "avg gen {d:.1}  energy {d:.0}  aggr {d:.2}  trail {d:.2}", .{
            genr / d, energy / d, traits[@backingInt(gen.Trait.aggression)] / d, traits[@backingInt(gen.Trait.trail_output)] / d,
        });
        y += 62;
    }
    drawHistory(w, px + 12, y + 4, 276, 100);

    if (app.show_gens) drawGenerationsPanel(app, sw);

    // Legend / key below society panel.
    if (app.show_key) {
        drawKey(app, px, 324);
    } else if (ui.button(rect(sw - 122, 324, 110, 28), "Key (L)", .{})) {
        app.show_key = true;
    }

    // Buttons + zoom controls + help.
    const labels = [_][]const u8{
        if (app.paused) "Resume" else "Pause",
        "",
        "",
        "",
        "Restart",
    };
    const btns = buttonRects();
    for (btns, 0..) |r, i| {
        const hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), r);
        rl.DrawRectangleRounded(r, 0.3, 6, if (hover) rgb(60, 66, 90) else rgb(36, 40, 58));
        var buf: [64]u8 = undefined;
        const label: []const u8 = switch (i) {
            1 => try std.fmt.bufPrint(&buf, "Speed x{d}", .{speeds[app.speed]}),
            2 => try std.fmt.bufPrint(&buf, "Food: {s}", .{@tagName(w.scarcity)}),
            3 => try std.fmt.bufPrint(&buf, "Overlay: {s}", .{@tagName(app.overlay)}),
            else => labels[i],
        };
        text(r.x + 10, r.y + 8, 14, rgb(225, 225, 235), "{s}", .{label});
    }

    const zx = btns[4].x + btns[4].width + 18;
    const zy = sh - 44;
    const zoom_pct: u32 = @intFromFloat(@round(app.camera.zoom / fitZoom() * 100));
    if (ui.button(rect(zx, zy, 34, 30), " -", .{})) zoomBy(&app.camera, 1.0 / 1.25, null);
    if (ui.button(rect(zx + 38, zy, 80, 30), "Fit {d}%", .{zoom_pct})) {
        app.follow = false;
        fitCamera(&app.camera);
    }
    if (ui.button(rect(zx + 122, zy, 34, 30), " +", .{})) zoomBy(&app.camera, 1.25, null);

    text(16, sh - 66, 12, rgb(130, 135, 150), "WASD/drag pan  wheel or [/] zoom  0 fit  click select  C follow  B brain  G generations  L key  P overlay  F food  +/- speed  Space pause  R restart", .{});
    text(sw - 560, sh - 22, 11, rgb(100, 105, 120), "Fly circuit: FlyWire connectome v783 (Dorkenwald et al. 2024; Schlegel et al. 2024; Shiu et al. 2024)", .{});

    if (app.selected) |id| {
        if (w.findById(id)) |e| try drawInspector(app, e);
    }
}

fn drawStatusBadge(x: f32, y: f32, st: sim.SocietyStatus) void {
    const label, const bg, const fg = switch (st) {
        .thriving => .{ "THRIVING", rgb(26, 78, 48), rgb(110, 240, 150) },
        .stable => .{ "STABLE", rgb(34, 44, 68), rgb(165, 190, 230) },
        .struggling => .{ "LOW", rgb(82, 62, 22), rgb(250, 205, 95) },
        .endangered => .{ "ENDANGERED", rgb(110, 32, 32), rgb(255, 130, 120) },
        .extinct => .{ "EXTINCT", rgb(56, 24, 28), rgb(210, 110, 110) },
    };
    const w: f32 = if (st == .endangered) 84 else 68;
    rl.DrawRectangleRounded(rect(x, y, w, 15), 0.4, 4, bg);
    text(x + 6, y + 2, 10, fg, "{s}", .{label});
}

fn drawAlertBar(app: *App, sw: f32) void {
    const w = &app.world;
    const bw: f32 = 460;
    const bx = (sw - bw) * 0.5;
    if (bx < 322) return;
    const r = rect(bx, 12, bw, 32);
    panel(r.x, r.y, r.width, r.height);

    // Highlight border if any society is endangered or extinct.
    var urgent = false;
    for (w.stats) |st| {
        if (st.status == .endangered or st.status == .extinct) urgent = true;
    }
    if (urgent) rl.DrawRectangleRoundedLinesEx(r, 0.04, 6, 1.5, withAlpha(rgb(255, 110, 90), 170));

    if (w.event_count > 0) {
        const ev = w.events[w.event_count - 1];
        const col = eventColor(ev);
        rl.DrawCircleV(.{ .x = bx + 16, .y = 28 }, 4.5, col);
        var buf: [128]u8 = undefined;
        const msg = formatEvent(&buf, ev);
        text(bx + 28, 20, 12, rgb(225, 230, 240), "{s}", .{msg});
    } else {
        rl.DrawCircleV(.{ .x = bx + 16, .y = 28 }, 4.5, rgb(110, 210, 140));
        text(bx + 28, 20, 12, rgb(175, 180, 195), "All societies active — press G for updates & generations", .{});
    }

    const btn = rect(bx + bw - 92, 17, 84, 22);
    const hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), btn);
    rl.DrawRectangleRounded(btn, 0.35, 6, if (hover) rgb(60, 68, 94) else rgb(36, 42, 60));
    text(btn.x + 8, btn.y + 4, 11, rgb(215, 220, 235), "{s}", .{if (app.show_gens) "Hide G" else "History G"});
    if (hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) app.show_gens = !app.show_gens;
}

fn drawGenerationsPanel(app: *App, sw: f32) void {
    const w = &app.world;
    const pw: f32 = 460;
    const px = (sw - pw) * 0.5;
    if (px < 322) return;
    const py: f32 = 52;
    const ph: f32 = 382;
    panel(px, py, pw, ph);

    var y = py + 12;
    text(px + 14, y, 15, rgb(235, 235, 245), "Civilization Updates, Roles & Generations", .{});
    y += 24;

    // 1. Live Civilization Updates
    text(px + 14, y, 12, rgb(210, 215, 230), "Recent updates", .{});
    y += 17;
    if (w.event_count == 0) {
        text(px + 20, y, 11, rgb(150, 155, 170), "No milestones or alerts yet.", .{});
        y += 18;
    } else {
        const show = @min(w.event_count, 5);
        for (0..show) |k| {
            const ev = w.events[w.event_count - 1 - k];
            rl.DrawCircleV(.{ .x = px + 20, .y = y + 6 }, 3.8, eventColor(ev));
            var buf: [128]u8 = undefined;
            const msg = formatEvent(&buf, ev);
            text(px + 30, y, 11, rgb(200, 205, 220), "{s}", .{msg});
            y += 16;
        }
    }

    y += 8;
    // 2. Emergent Society Roles
    text(px + 14, y, 12, rgb(210, 215, 230), "Emergent roles (from learned skills)", .{});
    y += 18;
    for (sim.societies, 0..) |s, si| {
        var counts: [7]u32 = @splat(0);
        var avg_sk: [sim.skill_count]f32 = @splat(0);
        var n: f32 = 0;
        for (w.entities.items) |e| {
            if (e.dead != null or e.society != si) continue;
            n += 1;
            counts[@backingInt(e.role())] += 1;
            for (&avg_sk, e.skills) |*a, v| a.* += v;
        }
        const d = @max(n, 1);
        text(px + 14, y, 12, societyColor(s), "{s}", .{s.name});
        text(px + 92, y, 11, rgb(185, 190, 205), "foragers {d}  scouts {d}  guards {d}  care {d}  elders {d}", .{
            counts[@backingInt(sim.Role.forager)],
            counts[@backingInt(sim.Role.scout)],
            counts[@backingInt(sim.Role.guard)],
            counts[@backingInt(sim.Role.caretaker)],
            counts[@backingInt(sim.Role.elder)],
        });
        y += 15;
        text(px + 92, y, 10, rgb(140, 148, 165), "avg skills: forage {d:.0}%  nav {d:.0}%  combat {d:.0}%  care {d:.0}%", .{
            avg_sk[0] / d * 100, avg_sk[1] / d * 100, avg_sk[2] / d * 100, avg_sk[3] / d * 100,
        });
        y += 17;
    }

    y += 6;
    // 3. Generation Progression Table (inherited skills, traits & cognitive brain growth)
    text(px + 14, y, 12, rgb(210, 215, 230), "Generations (skills, traits & cognitive brain at birth)", .{});
    y += 18;
    text(px + 14, y, 10, rgb(135, 142, 160), "Gen   Births  Forage  Nav   Comb  Care   Neur  Syn   Eff", .{});
    y += 15;
    const total_recs = w.gen_record_count;
    const start_rec = total_recs -| 6;
    for (start_rec..total_recs) |idx| {
        const rec = w.gen_records[idx];
        if (rec.births == 0) continue;
        const b: f32 = @floatFromInt(rec.births);
        text(px + 14, y, 10, rgb(205, 210, 225), "G{d:<3}  {d:<5}   {d:>3.0}%   {d:>3.0}%  {d:>3.0}%  {d:>3.0}%   {d:>4.1}  {d:>4.0}  {d:.2}", .{
            rec.gen,
            rec.births,
            rec.skill_sum[0] / b * 100,
            rec.skill_sum[1] / b * 100,
            rec.skill_sum[2] / b * 100,
            rec.skill_sum[3] / b * 100,
            rec.neuron_sum / b,
            rec.synapse_sum / b,
            rec.trait_eff_sum / b,
        });
        y += 15;
    }
}

fn drawPhaseBadge(x: f32, y: f32, p: sim.WorldPhase) void {
    const label, const bg, const fg = switch (p) {
        .calm => .{ "CALM", rgb(34, 44, 66), rgb(165, 195, 235) },
        .bloom => .{ "BLOOM", rgb(26, 74, 50), rgb(120, 240, 165) },
        .storm => .{ "STORM", rgb(56, 42, 86), rgb(190, 170, 255) },
    };
    rl.DrawRectangleRounded(rect(x, y, 64, 17), 0.4, 4, bg);
    text(x + 8, y + 3, 10, fg, "{s}", .{label});
}

fn formatEvent(buf: []u8, ev: sim.WorldEvent) []const u8 {
    const mins: u32 = @intFromFloat(ev.time / 60);
    const secs: u32 = @intFromFloat(@mod(ev.time, 60));
    const name = sim.societies[ev.society].name;
    return switch (ev.kind) {
        .endangered => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} endangered ({d} left)", .{ mins, secs, name, ev.value }),
        .critical => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} near extinction ({d} left!)", .{ mins, secs, name, ev.value }),
        .extinct => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} went extinct (reached Gen {d})", .{ mins, secs, name, ev.value }),
        .recovered => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} recovered ({d} strong)", .{ mins, secs, name, ev.value }),
        .boom => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} booming ({d} population)", .{ mins, secs, name, ev.value }),
        .milestone_gen => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} reached Generation {d}", .{ mins, secs, name, ev.value }),
        .first_hybrid => std.fmt.bufPrint(buf, "{d}:{d:0>2}  First {s} hybrid born (Gen {d})", .{ mins, secs, name, ev.value }),
        .world_bloom => std.fmt.bufPrint(buf, "{d}:{d:0>2}  Wild bloom — abundant food growth", .{ mins, secs }),
        .world_storm => std.fmt.bufPrint(buf, "{d}:{d:0>2}  Harsh storm sweeping the frontier", .{ mins, secs }),
    } catch "";
}

fn eventColor(ev: sim.WorldEvent) rl.Color {
    return switch (ev.kind) {
        .endangered => rgb(250, 185, 70),
        .critical, .extinct => rgb(255, 85, 75),
        .recovered, .boom, .world_bloom => rgb(100, 235, 145),
        .milestone_gen => societyColor(sim.societies[ev.society]),
        .first_hybrid => rgb(255, 220, 70),
        .world_storm => rgb(175, 155, 255),
    };
}

fn drawKey(app: *App, x: f32, top: f32) void {
    const w: f32 = 300;
    const h: f32 = 304;
    panel(x, top, w, h);

    var y = top + 10;
    text(x + 12, y, 15, rgb(235, 235, 245), "Key", .{});
    const hide_r = rect(x + w - 66, y - 2, 54, 20);
    const hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), hide_r);
    rl.DrawRectangleRounded(hide_r, 0.35, 6, if (hover) rgb(58, 64, 88) else rgb(34, 38, 54));
    text(hide_r.x + 8, hide_r.y + 3, 11, rgb(190, 195, 210), "Hide L", .{});
    if (hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) app.show_key = false;
    y += 24;

    // Societies: shape, color, native food & habitat.
    for (sim.societies) |s| {
        const col = societyColor(s);
        const c = rl.Vector2{ .x = x + 22, .y = y + 7 };
        switch (s.shape) {
            .triangle => {
                rl.DrawPoly(c, 3, 7, -90, col);
                rl.DrawPolyLinesEx(c, 3, 7, -90, 1, rgb(0, 0, 0));
            },
            .circle => {
                rl.DrawCircleV(c, 6, col);
                rl.DrawCircleLinesV(c, 6, rgb(0, 0, 0));
                rl.DrawLineEx(c, .{ .x = c.x + 6, .y = c.y }, 1.2, rgb(0, 0, 0));
            },
            .square => {
                rl.DrawPoly(c, 4, 7.5, 45, col);
                rl.DrawPolyLinesEx(c, 4, 7.5, 45, 1, rgb(0, 0, 0));
            },
        }
        text(x + 36, y, 12, col, "{s}", .{s.name});
        text(x + 104, y, 11, rgb(165, 170, 185), "eats {s} ({s})", .{ @tagName(s.food), s.environment });
        y += 20;
    }

    y += 6;
    text(x + 12, y, 12, rgb(215, 220, 232), "Food & corpses", .{});
    y += 17;
    const foods = [_]struct { sim.FoodType, []const u8 }{
        .{ .meat, "Meat" },
        .{ .plant, "Plant" },
        .{ .mineral, "Mineral" },
        .{ .universal, "Universal (all)" },
    };
    for (foods, 0..) |f, i| {
        const cx = x + 22 + @as(f32, @floatFromInt(i % 2)) * 136;
        const cy = y + @as(f32, @floatFromInt(i / 2)) * 17;
        rl.DrawCircleV(.{ .x = cx, .y = cy + 6 }, 4.5, foodColor(f[0]));
        text(cx + 12, cy, 11, rgb(175, 180, 195), "{s}", .{f[1]});
    }
    y += 34;
    rl.DrawCircleV(.{ .x = x + 22, .y = y + 6 }, 4.5, rgb(150, 40, 40));
    text(x + 34, y, 11, rgb(175, 180, 195), "Corpse (rotting meat)", .{});
    y += 22;

    text(x + 12, y, 12, rgb(215, 220, 232), "Entity states", .{});
    y += 17;
    // Hybrid outline
    const hy = rl.Vector2{ .x = x + 22, .y = y + 6 };
    rl.DrawCircleV(hy, 5.5, rgb(90, 140, 255));
    rl.DrawCircleLinesV(hy, 6.2, rgb(255, 220, 60));
    text(x + 34, y, 11, rgb(175, 180, 195), "Hybrid (any, 50%)", .{});
    // Fighting outline
    const fg = rl.Vector2{ .x = x + 158, .y = y + 6 };
    rl.DrawPoly(fg, 3, 6.5, -90, rgb(255, 90, 80));
    rl.DrawPolyLinesEx(fg, 3, 6.5, -90, 1.5, rgb(255, 60, 60));
    text(x + 170, y, 11, rgb(175, 180, 195), "Fighting", .{});
    y += 18;
    // Feeding dot
    const fd = rl.Vector2{ .x = x + 22, .y = y + 6 };
    rl.DrawCircleV(fd, 5.5, rgb(90, 230, 120));
    rl.DrawCircleV(.{ .x = fd.x + 5.5, .y = fd.y }, 2.2, rgb(255, 255, 255));
    text(x + 34, y, 11, rgb(175, 180, 195), "Feeding (MN9)", .{});
    // Dim fill
    rl.DrawCircleV(.{ .x = x + 158, .y = y + 6 }, 5.5, rgb(42, 68, 110));
    text(x + 170, y, 11, rgb(175, 180, 195), "Dim = low energy", .{});
    y += 22;

    text(x + 12, y, 12, rgb(215, 220, 232), "Chemical overlays (P)", .{});
    y += 17;
    drawMultiGlowSwatch(x + 22, y + 6, &.{ rgb(255, 90, 80), rgb(90, 140, 255), rgb(90, 230, 120) });
    text(x + 34, y, 11, rgb(175, 180, 195), "Society trail (society colour)", .{});
    y += 17;
    drawGlowSwatch(x + 22, y + 6, rgb(255, 140, 40));
    text(x + 34, y, 11, rgb(175, 180, 195), "Alarm pheromone (fight / death)", .{});
    y += 17;
    drawMultiGlowSwatch(x + 22, y + 6, &.{ rgb(255, 107, 107), rgb(78, 205, 160), rgb(255, 235, 59) });
    text(x + 34, y, 11, rgb(175, 180, 195), "Food scent (food colour)", .{});
}

fn drawMultiGlowSwatch(cx: f32, cy: f32, cols: []const rl.Color) void {
    const offsets = [_][2]f32{ .{ -3.5, 0 }, .{ 0, -2.5 }, .{ 3.5, 1 } };
    for (cols, 0..) |col, i| {
        const o = offsets[i % offsets.len];
        rl.DrawCircleV(.{ .x = cx + o[0], .y = cy + o[1] }, 4.5, withAlpha(col, 80));
        rl.DrawCircleV(.{ .x = cx + o[0], .y = cy + o[1] }, 2.0, withAlpha(col, 210));
    }
}

fn drawGlowSwatch(cx: f32, cy: f32, col: rl.Color) void {
    rl.DrawCircleV(.{ .x = cx, .y = cy }, 7, withAlpha(col, 45));
    rl.DrawCircleV(.{ .x = cx, .y = cy }, 4.5, withAlpha(col, 110));
    rl.DrawCircleV(.{ .x = cx, .y = cy }, 2.2, withAlpha(col, 200));
}

fn drawHistory(w: *const World, x: f32, y: f32, width: f32, height: f32) void {
    rl.DrawRectangleRec(rect(x, y, width, height), rgb(20, 22, 32));
    if (w.history_count < 2) return;
    var peak: f32 = 10;
    for (w.history[0..w.history_count]) |row| for (row) |v| {
        peak = @max(peak, @as(f32, @floatFromInt(v)));
    };
    const step = width / @as(f32, @floatFromInt(w.history_count - 1));
    for (sim.societies, 0..) |s, si| {
        for (1..w.history_count) |i| {
            const a = w.history[i - 1][si];
            const b = w.history[i][si];
            rl.DrawLineEx(
                .{ .x = x + step * @as(f32, @floatFromInt(i - 1)), .y = y + height - height * @as(f32, @floatFromInt(a)) / peak },
                .{ .x = x + step * @as(f32, @floatFromInt(i)), .y = y + height - height * @as(f32, @floatFromInt(b)) / peak },
                1.5,
                societyColor(s),
            );
        }
    }
    text(x + 4, y + 2, 10, rgb(120, 125, 140), "population (peak {d:.0})", .{peak});
}

fn drawInspector(app: *App, e: *const sim.Entity) !void {
    const s = sim.societies[e.society];
    const x: f32 = 12;
    var y: f32 = 114;
    const h: f32 = if (app.show_brain) 654 else 494;
    panel(x, y, 300, h);
    y += 8;
    text(x + 12, y, 17, societyColor(s), "{s} #{d}", .{ s.name, e.id });
    text(x + 136, y + 3, 12, rgb(170, 210, 240), "{s}", .{@tagName(e.role())});
    if (e.hybrid) text(x + 218, y + 3, 12, rgb(255, 220, 60), "HYBRID", .{});
    y += 22;
    text(x + 12, y, 11, rgb(190, 195, 210), "gen {d}  lin #{d}  age {d:.1}/{d:.0}m  kids {d}  kills {d}", .{ e.generation, e.lineage, e.age / 60, e.lifespan / 60, e.children, e.kills });
    y += 15;
    const suffix: []const u8 = if (e.feeding)
        " (feeding)"
    else if (app.world.phase == .storm and e.huddled)
        " (huddled)"
    else if (e.visible_food != null)
        " (food in sight)"
    else if (e.explore_target != null)
        " (exploring)"
    else
        "";
    text(x + 12, y, 11, rgb(190, 195, 210), "parents #{d} & #{d}   action: {s}{s}", .{ e.parents[0], e.parents[1], @tagName(e.action), suffix });
    y += 17;
    bar(x + 12, y, "energy", e.energy / sim.max_energy, energyColor(e.energy));
    y += 18;

    text(x + 12, y, 12, rgb(235, 235, 245), "Senses -> fly circuit", .{});
    y += 15;
    const sense = e.senses;
    bar2(x + 12, y, "odour L/R", sense.attr_L, sense.attr_R, rgb(120, 220, 160));
    y += 14;
    bar2(x + 12, y, "alarm L/R", sense.alarm_L, sense.alarm_R, rgb(255, 140, 60));
    y += 14;
    bar2(x + 12, y, "sugar/bitter", sense.sugar, sense.bitter, rgb(240, 220, 120));
    y += 17;

    text(x + 12, y, 12, rgb(235, 235, 245), "Fly motor output", .{});
    y += 15;
    const m = e.motor;
    bar2(x + 12, y, "DNa01/02 L/R", m.turn_L * 5, m.turn_R * 5, rgb(140, 180, 255));
    y += 14;
    bar(x + 12, y, "DNp09 walk", m.fwd, rgb(140, 180, 255));
    y += 14;
    bar(x + 12, y, "MDN back", m.back, rgb(140, 180, 255));
    y += 14;
    bar(x + 12, y, "giant fibre", m.escape, rgb(140, 180, 255));
    y += 14;
    bar(x + 12, y, "MN9 feed", m.feed, rgb(140, 180, 255));
    y += 17;

    text(x + 12, y, 12, rgb(235, 235, 245), "Learned skills (passed down)", .{});
    y += 15;
    for (e.skills, 0..) |v, i| {
        bar(x + 12, y, @tagName(@as(sim.Skill, @fromBackingInt(@intCast(i)))), v, rgb(95, 220, 195));
        y += 13;
    }
    y += 4;

    text(x + 12, y, 12, rgb(235, 235, 245), "Genes", .{});
    y += 15;
    for (e.genome.traits, 0..) |v, i| {
        bar(x + 12, y, @tagName(@as(gen.Trait, @fromBackingInt(@intCast(i)))), v, rgb(180, 160, 255));
        y += 13;
    }

    if (app.show_brain) {
        y += 5;
        const cog = &e.genome.cog;
        text(x + 12, y, 11, rgb(235, 235, 245), "Cognitive brain ({d} neurons, {d} synapses, +{d} grown)", .{
            cog.totalNeurons(), cog.activeSynapses(), cog.lifetime_rewires,
        });
        y += 14;
        drawCognitiveGraph(cog, x + 12, y, 276, 54);
        y += 58;

        const c = app.world.circuit;
        text(x + 12, y, 11, rgb(235, 235, 245), "FlyWire brainstem ({d} neurons, {d} synapses)", .{ c.neurons, c.connections() });
        y += 13;
        const cols: usize = 68;
        const cell: f32 = 4;
        for (e.brain.r, 0..) |r, i| {
            const cx = x + 12 + @as(f32, @floatFromInt(i % cols)) * cell;
            const cy = y + @as(f32, @floatFromInt(i / cols)) * cell;
            const v: u8 = @intFromFloat(std.math.clamp(r, 0, 1) * 255);
            rl.DrawRectangleRec(rect(cx, cy, cell - 0.8, cell - 0.8), .{ .r = v, .g = @intFromFloat(@as(f32, @floatFromInt(v)) * 0.7), .b = 40 + v / 3, .a = 255 });
        }
    }
}

fn drawCognitiveGraph(cog: *const gen.CognitiveBrain, x: f32, y: f32, w: f32, h: f32) void {
    rl.DrawRectangleRec(rect(x, y, w, h), rgb(16, 18, 28));
    var pos: [gen.max_cog_nodes]rl.Vector2 = undefined;
    // Inputs on left column.
    for (0..gen.social_inputs) |i| {
        const t = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, gen.social_inputs);
        pos[i] = .{ .x = x + 10, .y = y + 3 + t * (h - 6) };
    }
    // Hidden neurons in middle columns (split across 2 columns when > 8).
    const hc: usize = cog.hidden_count;
    for (0..hc) |hi| {
        const col_frac: f32 = if (hc <= 8) 0.5 else if (hi % 2 == 0) 0.38 else 0.62;
        const per_col: f32 = if (hc <= 8) @floatFromInt(hc) else @floatFromInt((hc + 1) / 2);
        const row: f32 = @floatFromInt(if (hc <= 8) hi else hi / 2);
        const t = (row + 0.5) / @max(per_col, 1);
        pos[gen.social_inputs + hi] = .{ .x = x + w * col_frac, .y = y + 4 + t * (h - 8) };
    }
    // Outputs on right column.
    for (0..gen.social_outputs) |oi| {
        const t = (@as(f32, @floatFromInt(oi)) + 0.5) / @as(f32, gen.social_outputs);
        pos[gen.out_base + oi] = .{ .x = x + w - 10, .y = y + 5 + t * (h - 10) };
    }

    // Synapses: green = excitatory, red = inhibitory, brightness = strength.
    for (cog.synapses[0..cog.synapse_count]) |s| {
        if (!s.active) continue;
        const mag = std.math.clamp(@abs(s.weight) / 2.0, 0.15, 1.0);
        const alpha: u8 = @intFromFloat(mag * 145);
        const col = if (s.weight >= 0) withAlpha(rgb(90, 225, 150), alpha) else withAlpha(rgb(245, 95, 95), alpha);
        rl.DrawLineEx(pos[s.from], pos[s.to], 0.9 + 0.6 * mag, col);
    }

    // Nodes: brightness reflects live activation.
    for (0..gen.social_inputs) |i| {
        const a = std.math.clamp(@abs(cog.act[i]), 0, 1);
        rl.DrawCircleV(pos[i], 2.0, rgb(80 + @as(u8, @intFromFloat(a * 160)), 110 + @as(u8, @intFromFloat(a * 130)), 170));
    }
    for (0..hc) |hi| {
        const idx = gen.social_inputs + hi;
        const a = std.math.clamp(@abs(cog.act[idx]), 0, 1);
        rl.DrawCircleV(pos[idx], 3.0, rgb(95 + @as(u8, @intFromFloat(a * 155)), 195 + @as(u8, @intFromFloat(a * 55)), 190));
    }
    for (0..gen.social_outputs) |oi| {
        const idx = gen.out_base + oi;
        const a = std.math.clamp(@abs(cog.act[idx]), 0, 1);
        rl.DrawCircleV(pos[idx], 3.2, withAlpha(actionColor(@fromBackingInt(@intCast(oi))), 110 + @as(u8, @intFromFloat(a * 145))));
    }
}

// ---------------------------------------------------------------- helpers

fn v2(p: sim.Vec2) rl.Vector2 {
    return .{ .x = p.x, .y = p.y };
}

fn societyColor(s: sim.Society) rl.Color {
    return rgb(s.color[0], s.color[1], s.color[2]);
}

fn foodColor(t: sim.FoodType) rl.Color {
    return switch (t) {
        .meat => rgb(255, 107, 107),
        .plant => rgb(78, 205, 160),
        .mineral => rgb(149, 200, 240),
        .universal => rgb(255, 235, 59),
    };
}

fn actionColor(a: gen.SocialAction) rl.Color {
    return switch (a) {
        .forage => rgb(200, 200, 200),
        .fight => rgb(255, 70, 70),
        .mate => rgb(255, 120, 220),
        .socialize => rgb(120, 200, 255),
        .flee => rgb(255, 200, 80),
    };
}

fn energyColor(energy: f32) rl.Color {
    return if (energy > 60) rgb(80, 220, 100) else if (energy > 30) rgb(240, 210, 60) else rgb(240, 70, 60);
}
