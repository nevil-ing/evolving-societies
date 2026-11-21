//! Interactive 2D view: societies, chemical overlays, HUD, key/legend, and
//! live fly-brain inspector.

const std = @import("std");
const rl = @import("raylib");
const fly = @import("flybrain.zig");
const gen = @import("genome.zig");
const sim = @import("world.zig");
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
    camera: rl.Camera2D,
    paused: bool = false,
    speed: usize = 0,
    overlay: Overlay = .trails,
    selected: ?u32 = null,
    follow: bool = false,
    show_brain: bool = true,
    show_key: bool = true,
    field_tex: rl.Texture2D,
    field_px: []u8,
};

pub fn run(gpa: std.mem.Allocator, opts: ui.Options) !void {
    const circuit = try fly.Circuit.parse(gpa, @embedFile("flybrain"));
    const shot = opts.shot;
    const warmup = opts.warmup;
    const shot_zoom = opts.zoom orelse 1.6;

    var app = App{
        .world = try World.init(gpa, &circuit, opts.seed orelse newSeed()),
        .camera = .{ .offset = .{ .x = 0, .y = 0 }, .target = .{ .x = 0, .y = 0 }, .rotation = 0, .zoom = 1 },
        .field_tex = undefined,
        .field_px = undefined,
    };
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
            for (0..speeds[app.speed]) |_| try app.world.step(1.0 / 60.0);
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
    try app.world.reset(newSeed());
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
    rl.DrawRectangleRec(rect(b.x, b.y, b.w, b.h), rgb(16, 18, 28));
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
        drawEntity(e, zoom, selected == e);
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
        if (target) |t| rl.DrawLineEx(v2(e.pos), v2(t), 1.5 / zoom, withAlpha(actionColor(e.action), 160));
    }
}

fn drawEntity(e: *const sim.Entity, zoom: f32, selected: bool) void {
    const s = sim.societies[e.society];
    const grow = 0.55 + 0.45 * @min(1, e.age / sim.maturity_age);
    const size = 8 * grow;
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
    text(110, 25, 14, rgb(170, 175, 190), "{s}  x{d}", .{ if (app.paused) "PAUSED" else "running", speeds[app.speed] });
    text(24, 50, 14, rgb(200, 200, 215), "Population {d}   Max generation {d}", .{ total, w.max_generation });
    text(24, 70, 14, rgb(200, 200, 215), "Food: {s}   Overlay: {s}", .{ @tagName(w.scarcity), @tagName(app.overlay) });

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
        text(px + 130, y + 3, 14, rgb(220, 220, 230), "pop {d:.0}  hybrids {d}", .{ n, hybrids });
        text(px + 12, y + 22, 12, rgb(170, 175, 190), "births {d}  starved {d}  old {d}  killed {d}", .{ st.births, st.deaths[0], st.deaths[1], st.deaths[2] });
        text(px + 12, y + 38, 12, rgb(170, 175, 190), "avg gen {d:.1}  energy {d:.0}  aggr {d:.2}  trail {d:.2}", .{
            genr / d, energy / d, traits[@backingInt(gen.Trait.aggression)] / d, traits[@backingInt(gen.Trait.trail_output)] / d,
        });
        y += 62;
    }
    drawHistory(w, px + 12, y + 4, 276, 100);

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

    text(16, sh - 66, 12, rgb(130, 135, 150), "WASD/drag pan  wheel or [/] zoom  0 fit  click select  C follow  B brain  L key  P overlay  F food  +/- speed  Space pause  R restart", .{});
    text(sw - 560, sh - 22, 11, rgb(100, 105, 120), "Fly circuit: FlyWire connectome v783 (Dorkenwald et al. 2024; Schlegel et al. 2024; Shiu et al. 2024)", .{});

    if (app.selected) |id| {
        if (w.findById(id)) |e| try drawInspector(app, e);
    }
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
    text(x + 34, y, 11, rgb(175, 180, 195), "Hybrid (eats any)", .{});
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
    drawGlowSwatch(x + 22, y + 6, rgb(90, 230, 120));
    text(x + 34, y, 11, rgb(175, 180, 195), "Society trail (laid after eating)", .{});
    y += 17;
    drawGlowSwatch(x + 22, y + 6, rgb(255, 140, 40));
    text(x + 34, y, 11, rgb(175, 180, 195), "Alarm pheromone (fight / death)", .{});
    y += 17;
    drawGlowSwatch(x + 22, y + 6, rgb(255, 235, 59));
    text(x + 34, y, 11, rgb(175, 180, 195), "Food scent (in scent overlay)", .{});
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
    var y: f32 = 116;
    const h: f32 = if (app.show_brain) 640 else 470;
    panel(x, y, 300, h);
    y += 10;
    text(x + 12, y, 18, societyColor(s), "{s} #{d}", .{ s.name, e.id });
    if (e.hybrid) text(x + 200, y + 3, 14, rgb(255, 220, 60), "HYBRID", .{});
    y += 24;
    text(x + 12, y, 12, rgb(190, 195, 210), "gen {d}  age {d:.0}/{d:.0}s  children {d}  kills {d}", .{ e.generation, e.age, e.lifespan, e.children, e.kills });
    y += 16;
    text(x + 12, y, 12, rgb(190, 195, 210), "parents #{d} & #{d}   action: {s}{s}", .{ e.parents[0], e.parents[1], @tagName(e.action), if (e.feeding) " (feeding)" else "" });
    y += 20;
    bar(x + 12, y, "energy", e.energy / sim.max_energy, energyColor(e.energy));
    y += 22;

    text(x + 12, y, 13, rgb(235, 235, 245), "Senses -> fly circuit", .{});
    y += 18;
    const sense = e.senses;
    bar2(x + 12, y, "odour L/R", sense.attr_L, sense.attr_R, rgb(120, 220, 160));
    y += 16;
    bar2(x + 12, y, "alarm L/R", sense.alarm_L, sense.alarm_R, rgb(255, 140, 60));
    y += 16;
    bar2(x + 12, y, "sugar/bitter", sense.sugar, sense.bitter, rgb(240, 220, 120));
    y += 22;

    text(x + 12, y, 13, rgb(235, 235, 245), "Fly motor output", .{});
    y += 18;
    const m = e.motor;
    bar2(x + 12, y, "DNa01/02 L/R", m.turn_L * 5, m.turn_R * 5, rgb(140, 180, 255));
    y += 16;
    bar(x + 12, y, "DNp09 walk", m.fwd, rgb(140, 180, 255));
    y += 16;
    bar(x + 12, y, "MDN back", m.back, rgb(140, 180, 255));
    y += 16;
    bar(x + 12, y, "giant fibre", m.escape, rgb(140, 180, 255));
    y += 16;
    bar(x + 12, y, "MN9 feed", m.feed, rgb(140, 180, 255));
    y += 22;

    text(x + 12, y, 13, rgb(235, 235, 245), "Genes", .{});
    y += 18;
    for (e.genome.traits, 0..) |v, i| {
        bar(x + 12, y, @tagName(@as(gen.Trait, @fromBackingInt(@intCast(i)))), v, rgb(180, 160, 255));
        y += 14;
    }

    if (app.show_brain) {
        y += 8;
        const c = app.world.circuit;
        text(x + 12, y, 13, rgb(235, 235, 245), "Fly neurons ({d} neurons, {d} synapse links)", .{ c.neurons, c.connections() });
        y += 18;
        const cols: usize = 46;
        const cell: f32 = 6;
        for (e.brain.r, 0..) |r, i| {
            const cx = x + 12 + @as(f32, @floatFromInt(i % cols)) * cell;
            const cy = y + @as(f32, @floatFromInt(i / cols)) * cell;
            const v: u8 = @intFromFloat(std.math.clamp(r, 0, 1) * 255);
            rl.DrawRectangleRec(rect(cx, cy, cell - 1, cell - 1), .{ .r = v, .g = @intFromFloat(@as(f32, @floatFromInt(v)) * 0.7), .b = 40 + v / 3, .a = 255 });
        }
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
