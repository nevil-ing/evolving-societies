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
const release_batches = [_]usize{ 1, 5, 10, 25, 50 };
const food_batches = [_]usize{ 25, 75, 150, 300 };

const max_specimens = 16;

const Specimen = struct {
    id: u32,
    society: u8,
    generation: u32,
    lineage: u32,
    role: sim.Role,
    hybrid: bool,
    captured_at: f32,
    age: f32,
    children: u32,
    kills: u32,
    food_eaten: f32,
    distance_traveled: f32,
    traits: [gen.trait_count]f32,
    motor: [gen.motor_count]f32,
    skills: [sim.skill_count]f32,
    cog: gen.CognitiveBrain,
    fly_gain: []f32,
};

const App = struct {
    gpa: std.mem.Allocator,
    world: World,
    logger: log.RunLogger,
    camera: rl.Camera2D,
    paused: bool = false,
    speed: usize = 0,
    overlay: Overlay = .trails,
    selected: ?u32 = null,
    follow: bool = false,
    director: bool = false,
    director_timer: f32 = 0,
    director_target: sim.Vec2 = .{ .x = 0, .y = 0 },
    director_zoom: f32 = 1.45,
    director_caption: [96]u8 = @splat(0),
    director_caption_len: usize = 0,
    status_note: [80]u8 = @splat(0),
    status_note_len: usize = 0,
    status_note_timer: f32 = 0,
    show_brain: bool = true,
    show_key: bool = true,
    show_territories: bool = true,
    show_gens: bool = false,
    show_lab: bool = false,
    show_exp: bool = false,
    release_batch: usize = 0,
    food_batch: usize = 2,
    specimens: [max_specimens]Specimen = undefined,
    specimen_count: usize = 0,
    lab_active: usize = 0,
    lab_compare: ?usize = null,
    seen_events: usize = 0,
    toasts: [4]Toast = undefined,
    toast_count: usize = 0,
    field_tex: rl.Texture2D,
    field_px: []u8,
};

const Toast = struct {
    ev: sim.WorldEvent,
    age: f32 = 0,
};
const toast_duration: f32 = 7.0;

pub fn run(gpa: std.mem.Allocator, opts: ui.Options) !void {
    const circuit = try fly.Circuit.parse(gpa, @embedFile("flybrain"));
    const shot = opts.shot;
    const warmup = opts.warmup;
    const shot_zoom = opts.zoom orelse 1.6;

    const seed = opts.seed orelse newSeed();
    var app = App{
        .gpa = gpa,
        .world = try World.init(gpa, &circuit, seed),
        .logger = if (shot == null) log.RunLogger.init(seed, opts.out) else .{},
        .camera = .{ .offset = .{ .x = 0, .y = 0 }, .target = .{ .x = 0, .y = 0 }, .rotation = 0, .zoom = 1 },
        .field_tex = undefined,
        .field_px = undefined,
    };
    defer {
        for (app.specimens[0..app.specimen_count]) |sp| gpa.free(sp.fly_gain);
        app.logger.deinit();
    }
    if (opts.load_path) |lp| try app.world.loadSnapshot(lp);
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
            const prev_count = app.world.event_count;
            const prev_last: ?sim.WorldEvent = if (prev_count > 0) app.world.events[prev_count - 1] else null;
            for (0..speeds[app.speed]) |_| {
                try app.world.step(1.0 / 60.0);
                app.logger.maybeLog(&app.world);
            }
            if (app.world.event_count > 0) {
                const newest = app.world.events[app.world.event_count - 1];
                const is_new = app.world.event_count > prev_count or (prev_last != null and (newest.time != prev_last.?.time or newest.kind != prev_last.?.kind));
                if (is_new) pushToast(&app, newest);
            }
        }
        ageToasts(&app, rl.GetFrameTime());
        if (app.status_note_timer > 0) app.status_note_timer = @max(0, app.status_note_timer - rl.GetFrameTime());
        if (app.director) {
            updateDirector(&app, rl.GetFrameTime());
        } else if (app.selected) |id| {
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
        app.director = false;
        clampCamera(cam);
    }

    const raw_wheel = rl.GetMouseWheelMove();
    if (raw_wheel != 0 and !ui.mouseOverPanel()) {
        app.director = false;
        const wheel = std.math.clamp(raw_wheel, -1.5, 1.5);
        zoomBy(cam, @exp(wheel * 0.08), rl.GetMousePosition());
    }

    if (rl.IsKeyPressed(rl.KEY_LEFT_BRACKET)) zoomBy(cam, 1.0 / 1.25, null);
    if (rl.IsKeyPressed(rl.KEY_RIGHT_BRACKET)) zoomBy(cam, 1.25, null);
    if (rl.IsKeyPressed(rl.KEY_ZERO)) {
        app.follow = false;
        app.director = false;
        fitCamera(cam);
    }
    if (rl.IsKeyPressed(rl.KEY_V)) {
        app.director = !app.director;
        app.director_timer = 0;
        if (app.director) app.follow = false;
    }
    if (rl.IsKeyPressed(rl.KEY_K)) {
        if (app.world.saveSnapshot("world_snapshot.esav")) {
            setStatusNote(app, "Saved snapshot: world_snapshot.esav");
        } else |_| {
            setStatusNote(app, "Could not save world_snapshot.esav (read-only cwd)");
        }
    }
    if (rl.IsKeyPressed(rl.KEY_O)) {
        if (app.world.loadSnapshot("world_snapshot.esav")) {
            app.selected = null;
            setStatusNote(app, "Loaded snapshot: world_snapshot.esav");
        } else |_| {
            setStatusNote(app, "No compatible world_snapshot.esav found");
        }
    }

    if (rl.IsKeyPressed(rl.KEY_SPACE)) app.paused = !app.paused;
    if (rl.IsKeyPressed(rl.KEY_EQUAL) or rl.IsKeyPressed(rl.KEY_KP_ADD)) app.speed = @min(app.speed + 1, speeds.len - 1);
    if (rl.IsKeyPressed(rl.KEY_MINUS) or rl.IsKeyPressed(rl.KEY_KP_SUBTRACT)) app.speed -|= 1;
    if (rl.IsKeyPressed(rl.KEY_F)) cycleFood(app);
    if (rl.IsKeyPressed(rl.KEY_P)) cycleOverlay(app);
    if (rl.IsKeyPressed(rl.KEY_B)) app.show_brain = !app.show_brain;
    if (rl.IsKeyPressed(rl.KEY_L)) app.show_key = !app.show_key;
    if (rl.IsKeyPressed(rl.KEY_H)) app.show_territories = !app.show_territories;
    if (rl.IsKeyPressed(rl.KEY_G)) {
        app.show_gens = !app.show_gens;
        if (app.show_gens) {
            app.show_lab = false;
            app.show_exp = false;
        }
    }
    if (rl.IsKeyPressed(rl.KEY_T)) {
        app.show_lab = !app.show_lab;
        if (app.show_lab) {
            app.show_gens = false;
            app.show_exp = false;
        }
    }
    if (rl.IsKeyPressed(rl.KEY_E)) {
        app.show_exp = !app.show_exp;
        if (app.show_exp) {
            app.show_gens = false;
            app.show_lab = false;
        }
    }
    if (rl.IsKeyPressed(rl.KEY_S) and rl.IsKeyDown(rl.KEY_LEFT_SHIFT)) {
        if (app.selected) |id| if (app.world.findById(id)) |e| try captureSpecimen(app, e);
    }
    if (rl.IsKeyPressed(rl.KEY_C)) app.follow = !app.follow and app.selected != null;
    if (rl.IsKeyPressed(rl.KEY_R)) try restart(app);
    if (rl.IsKeyPressed(rl.KEY_ESCAPE)) {
        if (app.show_exp or app.show_lab or app.show_gens) {
            app.show_exp = false;
            app.show_lab = false;
            app.show_gens = false;
        } else {
            app.selected = null;
            app.follow = false;
        }
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
    // Subtle living soil backdrop: fertile nutrient-rich loam glows faint moss-earth,
    // depleted ground stays dark slate, and heavy organic waste shows warm amber tint.
    for (0..sim.grid_rows) |gy_i| {
        for (0..sim.grid_cols) |gx_i| {
            const ci = gy_i * sim.grid_cols + gx_i;
            const nut = w.soil_nutrients[ci];
            const wst = w.waste[ci];
            const cx = b.x + @as(f32, @floatFromInt(gx_i)) * sim.grid_cell;
            const cy = b.y + @as(f32, @floatFromInt(gy_i)) * sim.grid_cell;
            if (nut > 0.55) {
                const a: u8 = @intFromFloat(std.math.clamp((nut - 0.55) * 20.0, 0, 26));
                rl.DrawRectangleRec(rect(cx, cy, sim.grid_cell, sim.grid_cell), withAlpha(rgb(42, 92, 62), a));
            }
            if (wst > 0.25) {
                const wa: u8 = @intFromFloat(std.math.clamp((wst - 0.25) * 28.0, 0, 32));
                rl.DrawRectangleRec(rect(cx, cy, sim.grid_cell, sim.grid_cell), withAlpha(rgb(135, 92, 38), wa));
            }
        }
    }
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
    if (app.show_territories) {
        for (0..w.clade_count) |si| {
            const cl = w.clades[si];
            const alive = w.stats[si].status != .extinct;
            // Hide extinct minor diverged clades so the frontier stays uncluttered.
            if (!alive and si >= sim.society_count) continue;
            const t = w.territories[si];
            const col = cladeColor(cl);
            const ccol = withAlpha(col, if (alive) 70 else 25);
            const thick = 1.2 / @max(zoom, 0.45);
            const arm: f32 = 26;
            const x0 = t.x;
            const y0 = t.y;
            const x1 = t.x + t.w;
            const y1 = t.y + t.h;
            // Clean corner brackets only (zero muddy interior fill) so creatures & structures stay 100% clear.
            rl.DrawLineEx(.{ .x = x0, .y = y0 }, .{ .x = x0 + arm, .y = y0 }, thick, ccol);
            rl.DrawLineEx(.{ .x = x0, .y = y0 }, .{ .x = x0, .y = y0 + arm }, thick, ccol);
            rl.DrawLineEx(.{ .x = x1, .y = y0 }, .{ .x = x1 - arm, .y = y0 }, thick, ccol);
            rl.DrawLineEx(.{ .x = x1, .y = y0 }, .{ .x = x1, .y = y0 + arm }, thick, ccol);
            rl.DrawLineEx(.{ .x = x0, .y = y1 }, .{ .x = x0 + arm, .y = y1 }, thick, ccol);
            rl.DrawLineEx(.{ .x = x0, .y = y1 }, .{ .x = x0, .y = y1 - arm }, thick, ccol);
            rl.DrawLineEx(.{ .x = x1, .y = y1 }, .{ .x = x1 - arm, .y = y1 }, thick, ccol);
            rl.DrawLineEx(.{ .x = x1, .y = y1 }, .{ .x = x1, .y = y1 - arm }, thick, ccol);
            text(x0 + 8, y0 + 6, 17, withAlpha(col, if (alive) 105 else 40), "{s}", .{cl.name()});
            text(x0 + 8, y0 + 25, 11, withAlpha(rgb(190, 195, 210), if (alive) 65 else 25), "{s}", .{cl.environment()});
        }
    }

    if (app.overlay != .off) {
        paintField(app);
        const src = rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(w.field.cols), .height = @floatFromInt(w.field.rows) };
        const dst = rect(w.field.origin_x, w.field.origin_y, @as(f32, @floatFromInt(w.field.cols)) * w.field.cell, @as(f32, @floatFromInt(w.field.rows)) * w.field.cell);
        rl.DrawTexturePro(app.field_tex, src, dst, .{ .x = 0, .y = 0 }, 0, rgb(255, 255, 255));
    }

    // Persistent stigmergic structures (Shelters, Food Caches & Abandoned Ruins) drawn beneath creatures.
    for (w.structures.items) |st| {
        if (st.integrity <= 0) continue;
        const sc = if (st.ruined) rgb(125, 130, 145) else cladeColor(w.clades[@min(st.society, w.clade_count - 1)]);
        const c = v2(st.pos);
        const r = st.radius();
        const done = st.complete();
        const line_w = (if (done) @as(f32, 2.2) else 1.2) / @max(zoom, 0.5);
        switch (st.kind) {
            .shelter => {
                if (st.ruined) {
                    rl.DrawPolyLinesEx(c, 6, r, 30, 1.3 / @max(zoom, 0.5), withAlpha(sc, 95));
                    rl.DrawPolyLinesEx(c, 6, r * 0.72, 15, 1.0 / @max(zoom, 0.5), withAlpha(sc, 60));
                } else {
                    rl.DrawPoly(c, 6, r, 30, withAlpha(sc, if (done) 28 else 11));
                    rl.DrawPolyLinesEx(c, 6, r, 30, line_w, withAlpha(sc, if (done) 165 else 85));
                    if (done) {
                        rl.DrawPolyLinesEx(c, 6, r * 0.55, 30, 1.0 / @max(zoom, 0.5), withAlpha(rgb(235, 240, 255), 55));
                    }
                }
            },
            .cache => {
                const rr = rect(c.x - r * 0.65, c.y - r * 0.65, r * 1.3, r * 1.3);
                if (st.ruined) {
                    rl.DrawRectangleRoundedLinesEx(rr, 0.25, 4, 1.3 / @max(zoom, 0.5), withAlpha(sc, 95));
                } else {
                    rl.DrawRectangleRounded(rr, 0.25, 4, withAlpha(sc, if (done) 30 else 12));
                    rl.DrawRectangleRoundedLinesEx(rr, 0.25, 4, line_w, withAlpha(sc, if (done) 175 else 85));
                    if (done) {
                        const frac = std.math.clamp(st.stored_food / sim.max_cache_food, 0, 1);
                        rl.DrawRectangleRec(rect(c.x - 14, c.y - 3, 28, 6), rgb(24, 28, 40));
                        rl.DrawRectangleRec(rect(c.x - 14, c.y - 3, 28 * frac, 6), rgb(255, 220, 75));
                    }
                }
            },
        }
        if (!done and !st.ruined) {
            const pfrac = std.math.clamp(st.progress / 100, 0, 1);
            rl.DrawRectangleRec(rect(c.x - 14, c.y - 2, 28, 4), rgb(24, 28, 40));
            rl.DrawRectangleRec(rect(c.x - 14, c.y - 2, 28 * pfrac, 4), withAlpha(sc, 210));
        }
    }

    // Raw material nodes (wood timber & flint stone).
    for (w.materials.items) |mat| {
        if (mat.amount <= 0) continue;
        const c = v2(mat.pos);
        const sc_sz = 3.2 + 2.2 * std.math.clamp(mat.amount / 45, 0.3, 1);
        switch (mat.kind) {
            .wood => {
                rl.DrawRectangleRounded(rect(c.x - sc_sz, c.y - sc_sz * 0.55, sc_sz * 2, sc_sz * 1.1), 0.35, 4, rgb(176, 122, 68));
                rl.DrawRectangleRoundedLinesEx(rect(c.x - sc_sz, c.y - sc_sz * 0.55, sc_sz * 2, sc_sz * 1.1), 0.35, 4, 1.0 / @max(zoom, 0.5), rgb(96, 62, 32));
            },
            .stone => {
                rl.DrawPoly(c, 5, sc_sz * 1.05, 18, rgb(156, 168, 186));
                rl.DrawPolyLinesEx(c, 5, sc_sz * 1.05, 18, 1.0 / @max(zoom, 0.5), rgb(86, 96, 114));
            },
        }
    }

    for (w.resources.items) |r| {
        if (r.amount <= 0) continue;
        const radius = 2 + 3 * @sqrt(@min(r.amount, 40) / 40);
        const col = if (r.corpse) rgb(150, 40, 40) else foodColor(r.food);
        const c = v2(r.pos);
        rl.DrawCircleV(c, radius, col);
        if (r.food == .herb and !r.corpse) {
            rl.DrawCircleLinesV(c, radius + 1.8, withAlpha(rgb(235, 195, 255), 140));
        }
    }

    // Wild Prey (tough frontier quarry that rewards spears & group hunting).
    for (w.prey.items) |pr| {
        if (pr.hp <= 0) continue;
        const c = v2(pr.pos);
        const deg = pr.heading * 180 / std.math.pi;
        rl.DrawPoly(c, 6, 12, deg, rgb(212, 152, 72));
        rl.DrawPolyLinesEx(c, 6, 12, deg, 1.8 / @max(zoom, 0.5), rgb(255, 224, 155));
        rl.DrawLineEx(c, .{ .x = c.x + 12 * @cos(pr.heading), .y = c.y + 12 * @sin(pr.heading) }, 1.8 / @max(zoom, 0.5), rgb(85, 50, 18));
        if (pr.hp < pr.max_hp) {
            rl.DrawRectangleRec(rect(c.x - 12, c.y - 18, 24, 3), rgb(35, 35, 42));
            rl.DrawRectangleRec(rect(c.x - 12, c.y - 18, 24 * std.math.clamp(pr.hp / pr.max_hp, 0, 1), 3), rgb(245, 95, 75));
        }
    }

    // Apex Predators (crimson-violet frontier stalkers that hunt stragglers & force collective defense).
    for (w.predators.items) |pd| {
        if (pd.hp <= 0) continue;
        const c = v2(pd.pos);
        const deg = pd.heading * 180 / std.math.pi;
        rl.DrawCircleV(c, 19, withAlpha(rgb(220, 35, 75), 26));
        rl.DrawPoly(c, 4, 15.5, deg, rgb(125, 22, 58));
        rl.DrawPoly(c, 3, 14.0, deg, rgb(205, 38, 72));
        rl.DrawPolyLinesEx(c, 4, 15.5, deg, 1.8 / @max(zoom, 0.5), rgb(255, 110, 130));
        // Glowing red fangs/eyes facing forward
        const eye_l = rl.Vector2{ .x = c.x + 8 * @cos(pd.heading - 0.35), .y = c.y + 8 * @sin(pd.heading - 0.35) };
        const eye_r = rl.Vector2{ .x = c.x + 8 * @cos(pd.heading + 0.35), .y = c.y + 8 * @sin(pd.heading + 0.35) };
        rl.DrawCircleV(eye_l, 2.0, rgb(255, 225, 100));
        rl.DrawCircleV(eye_r, 2.0, rgb(255, 225, 100));
        if (pd.hp < pd.max_hp) {
            rl.DrawRectangleRec(rect(c.x - 14, c.y - 21, 28, 3.5), rgb(35, 24, 32));
            rl.DrawRectangleRec(rect(c.x - 14, c.y - 21, 28 * std.math.clamp(pd.hp / pd.max_hp, 0, 1), 3.5), rgb(255, 65, 95));
        }
    }

    const selected = if (app.selected) |id| w.findById(id) else null;
    for (w.entities.items) |*e| {
        if (e.dead != null) continue;
        if (w.phase == .storm and e.huddled) {
            rl.DrawCircleV(v2(e.pos), e.radius() + 6, withAlpha(rgb(155, 195, 255), 32));
        } else if (e.resting) {
            rl.DrawCircleLinesV(v2(e.pos), e.radius() + 3.5, withAlpha(rgb(175, 200, 235), 90));
        }
        if (e.infection) |inf| {
            const pulse = 1.0 + 0.25 * @sin(w.time * 6.0);
            const r_sick = e.radius() + 4.5 + 3.5 * inf.load * pulse;
            const alpha: u8 = @intFromFloat(std.math.clamp(90 + 135 * inf.load, 90, 225));
            rl.DrawCircleV(v2(e.pos), r_sick, withAlpha(rgb(185, 235, 65), alpha / 4));
            rl.DrawCircleLinesV(v2(e.pos), r_sick, withAlpha(rgb(185, 235, 65), alpha));
        }
        drawEntity(w, e, zoom, selected == e);
    }

    for (w.contacts[0..w.contact_count]) |ev| {
        const t = std.math.clamp(ev.age / sim.contact_duration, 0, 1);
        const alpha: u8 = @intFromFloat((1 - t) * 210);
        const col: rl.Color = switch (ev.kind) {
            .kin_greet => cladeColor(w.clades[@min(ev.society, w.clade_count - 1)]),
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

    for (w.signals[0..w.signal_count]) |sig| {
        const t = std.math.clamp(sig.age / sim.signal_duration, 0, 1);
        const alpha: u8 = @intFromFloat((1 - t) * (110 + 65 * sig.volume));
        const col: rl.Color = if (sig.kind) |k| switch (k) {
            .food_found => rgb(135, 240, 155),
            .danger_call => rgb(255, 85, 80),
            .storm_rally => rgb(140, 200, 255),
            .mate_call => rgb(245, 130, 230),
        } else vocalColor(sig.vec);
        const r = 10 + sig.radius * 0.45 * t;
        rl.DrawCircleLinesV(v2(sig.pos), r, withAlpha(col, alpha));
        if (t > 0.15) rl.DrawCircleLinesV(v2(sig.pos), r * 0.72, withAlpha(col, alpha / 2));
    }

    // Transient glowing gold-cyan gift & barter transfer arcs!
    for (w.trade_arcs[0..w.trade_arc_count]) |arc| {
        const t = std.math.clamp(arc.age / sim.trade_arc_duration, 0, 1);
        const alpha: u8 = @intFromFloat((1 - t) * 225);
        const col = if (arc.reciprocal) rgb(255, 220, 85) else if (arc.item == 4) rgb(210, 145, 255) else rgb(95, 235, 225);
        rl.DrawLineEx(v2(arc.from), v2(arc.to), (if (arc.reciprocal) @as(f32, 2.4) else 1.5) / @max(zoom, 0.5), withAlpha(col, alpha));
        const bx = arc.from.x + (arc.to.x - arc.from.x) * t;
        const by = arc.from.y + (arc.to.y - arc.from.y) * t;
        rl.DrawCircleV(.{ .x = bx, .y = by }, if (arc.reciprocal) 3.4 else 2.5, withAlpha(col, alpha));
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
        // Draw the selected entity's live Mental Map (episodic spatial memories).
        for (e.memories) |mem| {
            if (mem.confidence <= 0.12) continue;
            const mcol: rl.Color = switch (mem.kind) {
                .food => rgb(105, 235, 145),
                .material => rgb(195, 155, 95),
                .shelter => rgb(125, 200, 255),
                .danger => rgb(255, 85, 85),
                .prey => rgb(235, 175, 85),
            };
            const tag: [:0]const u8 = switch (mem.kind) {
                .food => "F",
                .material => "M",
                .shelter => "S",
                .danger => "!",
                .prey => "P",
            };
            const ma: u8 = @intFromFloat(std.math.clamp(mem.confidence, 0.2, 1.0) * 140);
            rl.DrawLineEx(v2(e.pos), v2(mem.pos), 1.0 / @max(zoom, 0.5), withAlpha(mcol, ma / 2));
            rl.DrawCircleLinesV(v2(mem.pos), 10 / @max(zoom, 0.5), withAlpha(mcol, ma));
            const msz: c_int = @intFromFloat(@max(10, 12 / @max(zoom, 0.5)));
            text(mem.pos.x - 3 / @max(zoom, 0.5), mem.pos.y - 6 / @max(zoom, 0.5), msz, withAlpha(mcol, @intCast(@min(255, @as(u16, ma) + 70))), "{s}", .{tag});
        }
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
        } else if (e.heard_kind != null) {
            rl.DrawLineEx(v2(e.pos), v2(e.heard_pos), 1.4 / zoom, withAlpha(rgb(140, 240, 175), 140));
            rl.DrawCircleLinesV(v2(e.heard_pos), 9 / @max(zoom, 0.4), withAlpha(rgb(140, 240, 175), 190));
        } else if (e.explore_target) |goal| {
            rl.DrawLineEx(v2(e.pos), v2(goal), 1.2 / zoom, withAlpha(rgb(95, 220, 210), 110));
            rl.DrawCircleLinesV(v2(goal), 8 / @max(zoom, 0.4), withAlpha(rgb(95, 220, 210), 170));
        }
    }
}

fn drawEntity(w: *const World, e: *const sim.Entity, zoom: f32, selected: bool) void {
    const cl = w.clades[@min(e.society, w.clade_count - 1)];
    const size = e.radius();
    const health = std.math.clamp(e.energy / 100, 0.25, 1);
    const base = cladeColor(cl);
    // Subtle 18% evolved diet-niche tint (meat=red, plant=emerald, mineral=sky) keeps clades legible while reflecting diet evolution.
    const diet_r = e.genome.digest[0] * 255 + e.genome.digest[1] * 78 + e.genome.digest[2] * 149;
    const diet_g = e.genome.digest[0] * 107 + e.genome.digest[1] * 205 + e.genome.digest[2] * 200;
    const diet_b = e.genome.digest[0] * 107 + e.genome.digest[1] * 160 + e.genome.digest[2] * 240;
    const col = rl.Color{
        .r = @intFromFloat(std.math.clamp((@as(f32, @floatFromInt(base.r)) * 0.82 + diet_r * 0.18) * health, 0, 255)),
        .g = @intFromFloat(std.math.clamp((@as(f32, @floatFromInt(base.g)) * 0.82 + diet_g * 0.18) * health, 0, 255)),
        .b = @intFromFloat(std.math.clamp((@as(f32, @floatFromInt(base.b)) * 0.82 + diet_b * 0.18) * health, 0, 255)),
        .a = 255,
    };
    const deg = e.heading * 180 / std.math.pi;
    const c = v2(e.pos);
    const outline: rl.Color = if (selected) rgb(255, 230, 80) else if (e.hybrid) rgb(255, 220, 60) else if (e.action == .fight) rgb(255, 60, 60) else rgb(0, 0, 0);
    const thick = (if (selected or e.hybrid) @as(f32, 2) else 1) / @max(zoom, 0.5);
    switch (cl.shape) {
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
        .diamond => {
            rl.DrawPoly(c, 4, size * 1.25, deg, col);
            rl.DrawPolyLinesEx(c, 4, size * 1.25, deg, thick, outline);
        },
        .pentagon => {
            rl.DrawPoly(c, 5, size * 1.15, deg, col);
            rl.DrawPolyLinesEx(c, 5, size * 1.15, deg, thick, outline);
        },
        .hexagon => {
            rl.DrawPoly(c, 6, size * 1.12, deg, col);
            rl.DrawPolyLinesEx(c, 6, size * 1.12, deg, thick, outline);
        },
    }
    if (e.stage() == .infant) {
        rl.DrawCircleLinesV(c, size + 2.0, withAlpha(rgb(255, 240, 195), 115));
    } else if (e.stage() == .elder) {
        rl.DrawCircleLinesV(c, size + 2.4, withAlpha(rgb(215, 225, 245), 115));
    }
    if (e.feeding) rl.DrawCircleV(.{ .x = c.x + size * @cos(e.heading), .y = c.y + size * @sin(e.heading) }, 2, rgb(255, 255, 255));
    // Visible carried materials, food packs, medicinal herbs & crafted tools (Spear / Basket).
    if (e.carrying != .none) {
        const carry_col: rl.Color = switch (e.carrying) {
            .wood => rgb(186, 130, 74),
            .stone => rgb(175, 188, 208),
            .food_pack => rgb(255, 225, 85),
            .herb => rgb(205, 125, 255),
            .none => rgb(200, 200, 200),
        };
        const sx = c.x + size * 0.9 * @cos(e.heading + 0.9);
        const sy = c.y + size * 0.9 * @sin(e.heading + 0.9);
        rl.DrawCircleV(.{ .x = sx, .y = sy }, 2.7, carry_col);
    }
    if (e.tool == .spear) {
        const tip = rl.Vector2{ .x = c.x + (size + 9) * @cos(e.heading), .y = c.y + (size + 9) * @sin(e.heading) };
        const hilt = rl.Vector2{ .x = c.x + size * 0.4 * @cos(e.heading), .y = c.y + size * 0.4 * @sin(e.heading) };
        rl.DrawLineEx(hilt, tip, 1.8 / @max(zoom, 0.55), rgb(235, 242, 255));
        rl.DrawCircleV(tip, 1.8, rgb(255, 245, 190));
    } else if (e.tool == .basket) {
        const bx = c.x - size * 0.85 * @cos(e.heading);
        const by = c.y - size * 0.85 * @sin(e.heading);
        rl.DrawCircleV(.{ .x = bx, .y = by }, 3.0, rgb(225, 185, 95));
    }
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
                // Wyatt (2010) 3-channel RGB chemical signature basis + 1 shared alarm channel.
                const t0 = @min(1, f.data[sim.trailChannel(0)][i] * 0.6);
                const t1 = @min(1, f.data[sim.trailChannel(1)][i] * 0.6);
                const t2 = @min(1, f.data[sim.trailChannel(2)][i] * 0.6);
                r += t0 * 255 + t1 * 90 + t2 * 90;
                g += t0 * 90 + t1 * 140 + t2 * 230;
                b += t0 * 80 + t1 * 255 + t2 * 120;
                const a = @min(1, f.data[sim.alarmChannel(0)][i] * 0.55);
                r += a * 255;
                g += a * 140;
                b += a * 40;
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
    for (0..w.clade_count) |s| total += w.population(s);
    text(24, 20, 22, rgb(235, 235, 245), "{d}:{d:0>2}", .{ mins, secs });
    text(100, 25, 13, rgb(170, 175, 190), "{s} x{d}", .{ if (app.paused) "PAUSED" else "running", speeds[app.speed] });
    drawPhaseBadge(210, 24, w.phase, sim.phaseRemaining(w.phaseClock()));
    if (w.clade_count > sim.society_count) {
        text(24, 50, 14, rgb(200, 200, 215), "Pop {d}  Clades {d}/{d}  Gen {d}", .{ total, w.activeCladeCount(), w.clade_count, w.max_generation });
    } else {
        text(24, 50, 14, rgb(200, 200, 215), "Population {d}   Max generation {d}", .{ total, w.max_generation });
    }
    text(24, 70, 13, rgb(200, 200, 215), "Food: {s}   Overlay: {s}", .{ @tagName(w.scarcity), @tagName(app.overlay) });
    if (w.pure_neural) {
        rl.DrawRectangleRounded(rect(210, 69, 92, 16), 0.4, 4, rgb(52, 38, 88));
        text(216, 71, 10, rgb(195, 165, 255), "PURE NEURAL", .{});
    } else {
        rl.DrawRectangleRounded(rect(224, 69, 78, 16), 0.4, 4, rgb(36, 44, 64));
        text(234, 71, 10, rgb(165, 185, 215), "ASSISTED", .{});
    }

    // Top-center civilization alert / updates bar (click or press G for full log & generations).
    drawAlertBar(app, sw);

    // Society panel + history chart (shows top 3 active clades dynamically when > 3 clades exist!).
    const px = sw - 312;
    const extra_clades = w.clade_count > 3;
    panel(px, 12, 300, if (extra_clades) 316 else 300);
    var y: f32 = 22;
    if (extra_clades) {
        text(px + 12, y - 4, 10, rgb(115, 225, 210), "Top 3 of {d} active clades ({d} total - G for all)", .{ w.activeCladeCount(), w.clade_count });
        y += 14;
    }
    var order: [sim.max_societies]usize = undefined;
    var pops: [sim.max_societies]u32 = undefined;
    for (0..w.clade_count) |si| {
        order[si] = si;
        pops[si] = w.population(si);
    }
    if (extra_clades) {
        // Rank by live population descending (with tie-break favoring founders).
        for (0..w.clade_count) |a| {
            var best = a;
            for (a + 1..w.clade_count) |b| {
                if (pops[order[b]] > pops[order[best]]) best = b;
            }
            const tmp = order[a];
            order[a] = order[best];
            order[best] = tmp;
        }
    }
    const show_n = @min(w.clade_count, 3);
    for (order[0..show_n]) |si| {
        const cl = w.clades[si];
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
        text(px + 12, y, 18, cladeColor(cl), "{s}", .{cl.name()});
        drawStatusBadge(px + 102, y + 3, st.status);
        text(px + 194, y + 3, 13, rgb(220, 220, 230), "pop {d:.0}  hyb {d}", .{ n, hybrids });
        text(px + 12, y + 22, 12, rgb(170, 175, 190), "births {d}  starved {d}  old {d}  killed {d}", .{ st.births, st.deaths[0], st.deaths[1], st.deaths[2] });
        text(px + 12, y + 38, 12, rgb(170, 175, 190), "avg gen {d:.1}  energy {d:.0}  aggr {d:.2}  trail {d:.2}", .{
            genr / d, energy / d, traits[@backingInt(gen.Trait.aggression)] / d, traits[@backingInt(gen.Trait.trail_output)] / d,
        });
        y += 62;
    }
    drawHistory(w, px + 12, y + 4, 276, 100);

    if (app.show_gens) {
        drawGenerationsPanel(app, sw);
    } else if (app.show_lab) {
        try drawLabPanel(app, sw);
    } else if (app.show_exp) {
        try drawExpPanel(app, sw);
    } else {
        drawToasts(app, sw);
    }

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
    if (smallBtn(rect(zx + 162, zy + 2, 92, 26), if (app.director) "Director ON" else "Director V", if (app.director) rgb(34, 96, 88) else rgb(38, 44, 62))) {
        app.director = !app.director;
        app.director_timer = 0;
        if (app.director) app.follow = false;
    }

    if (app.director and app.director_caption_len > 0) {
        const cw: f32 = 440;
        const cx = (sw - cw) * 0.5;
        if (cx > 322) {
            panel(cx, sh - 104, cw, 28);
            text(cx + 12, sh - 96, 12, rgb(125, 240, 225), "AUTO-DIRECTOR: {s}", .{app.director_caption[0..app.director_caption_len]});
        }
    } else if (app.status_note_timer > 0 and app.status_note_len > 0) {
        const cw: f32 = 380;
        const cx = (sw - cw) * 0.5;
        if (cx > 322) {
            panel(cx, sh - 104, cw, 28);
            text(cx + 12, sh - 96, 12, rgb(225, 225, 165), "{s}", .{app.status_note[0..app.status_note_len]});
        }
    }

    text(16, sh - 66, 11, rgb(130, 135, 150), "WASD/drag pan  wheel/[/] zoom  0 fit  V director  K/O save/load  C follow  B brain  G history  T lab  E controls  H borders  L key  P overlay  F food  +/- speed  Space pause  R restart", .{});
    text(sw - 505, sh - 21, 10, rgb(100, 105, 120), "Fly circuit: FlyWire connectome v783 (Dorkenwald et al. 2024; Schlegel et al. 2024; Shiu et al. 2024)", .{});

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
    const bw: f32 = 524;
    const bx = (sw - bw) * 0.5;
    if (bx < 322) return;
    const r = rect(bx, 12, bw, 32);
    panel(r.x, r.y, r.width, r.height);

    // Highlight border if any founder or persistent society is endangered or extinct.
    var urgent = false;
    for (w.stats[0..w.clade_count], 0..) |st, si| {
        if ((si < sim.society_count or st.peak_pop >= 4) and (st.status == .endangered or st.status == .extinct)) urgent = true;
    }
    if (urgent) rl.DrawRectangleRoundedLinesEx(r, 0.04, 6, 1.5, withAlpha(rgb(255, 110, 90), 170));

    if (w.event_count > 0) {
        const ev = w.events[w.event_count - 1];
        const col = eventColor(w, ev);
        rl.DrawCircleV(.{ .x = bx + 16, .y = 28 }, 4.5, col);
        var buf: [128]u8 = undefined;
        const msg = formatEvent(w, &buf, ev);
        text(bx + 28, 20, 12, rgb(225, 230, 240), "{s}", .{msg});
    } else {
        rl.DrawCircleV(.{ .x = bx + 16, .y = 28 }, 4.5, rgb(110, 210, 140));
        text(bx + 28, 20, 12, rgb(175, 180, 195), "All societies active - E controls, T lab, G history", .{});
    }

    const exp_btn = rect(bx + bw - 208, 17, 58, 22);
    const exp_hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), exp_btn);
    rl.DrawRectangleRounded(exp_btn, 0.35, 6, if (app.show_exp) rgb(76, 56, 98) else if (exp_hover) rgb(60, 68, 94) else rgb(36, 42, 60));
    text(exp_btn.x + 8, exp_btn.y + 4, 11, rgb(245, 195, 115), "Exp E", .{});
    if (exp_hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
        app.show_exp = !app.show_exp;
        if (app.show_exp) {
            app.show_gens = false;
            app.show_lab = false;
        }
    }

    const lab_btn = rect(bx + bw - 144, 17, 62, 22);
    const lab_hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), lab_btn);
    rl.DrawRectangleRounded(lab_btn, 0.35, 6, if (app.show_lab) rgb(44, 74, 82) else if (lab_hover) rgb(60, 68, 94) else rgb(36, 42, 60));
    text(lab_btn.x + 8, lab_btn.y + 4, 11, rgb(140, 225, 215), "Lab {d}", .{app.specimen_count});
    if (lab_hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
        app.show_lab = !app.show_lab;
        if (app.show_lab) {
            app.show_gens = false;
            app.show_exp = false;
        }
    }

    const btn = rect(bx + bw - 76, 17, 68, 22);
    const hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), btn);
    rl.DrawRectangleRounded(btn, 0.35, 6, if (app.show_gens) rgb(54, 66, 96) else if (hover) rgb(60, 68, 94) else rgb(36, 42, 60));
    text(btn.x + 8, btn.y + 4, 11, rgb(215, 220, 235), "{s}", .{if (app.show_gens) "Hide G" else "Hist G"});
    if (hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
        app.show_gens = !app.show_gens;
        if (app.show_gens) {
            app.show_lab = false;
            app.show_exp = false;
        }
    }
}

fn pushToast(app: *App, ev: sim.WorldEvent) void {
    // Routine weather phase flips already update both the phase badge and top ticker bar.
    if (ev.kind == .world_bloom or ev.kind == .world_storm) return;
    if (app.toast_count < app.toasts.len) {
        app.toasts[app.toast_count] = .{ .ev = ev };
        app.toast_count += 1;
    } else {
        std.mem.copyForwards(Toast, app.toasts[0 .. app.toasts.len - 1], app.toasts[1..]);
        app.toasts[app.toasts.len - 1] = .{ .ev = ev };
    }
}

fn ageToasts(app: *App, dt: f32) void {
    var i: usize = 0;
    while (i < app.toast_count) {
        app.toasts[i].age += dt;
        if (app.toasts[i].age >= toast_duration) {
            std.mem.copyForwards(Toast, app.toasts[i .. app.toast_count - 1], app.toasts[i + 1 .. app.toast_count]);
            app.toast_count -= 1;
            continue;
        }
        i += 1;
    }
}

fn drawToasts(app: *const App, sw: f32) void {
    if (app.toast_count == 0) return;
    const tw: f32 = 420;
    const tx = (sw - tw) * 0.5;
    if (tx < 322) return;
    var ty: f32 = 52;
    var k = app.toast_count;
    while (k > 0) {
        k -= 1;
        const t = app.toasts[k];
        const fade = std.math.clamp((toast_duration - t.age) / 1.2, 0, 1);
        const bg_a: u8 = @intFromFloat(fade * 225);
        const fg_a: u8 = @intFromFloat(fade * 255);
        const r = rect(tx, ty, tw, 28);
        const col = eventColor(&app.world, t.ev);
        rl.DrawRectangleRounded(r, 0.2, 6, .{ .r = 20, .g = 24, .b = 36, .a = bg_a });
        rl.DrawRectangleRoundedLinesEx(r, 0.2, 6, 1.2, withAlpha(col, @intFromFloat(fade * 170)));
        rl.DrawCircleV(.{ .x = tx + 14, .y = ty + 14 }, 4.2, withAlpha(col, fg_a));
        var buf: [128]u8 = undefined;
        const msg = formatEvent(&app.world, &buf, t.ev);
        text(tx + 26, ty + 7, 12, withAlpha(rgb(235, 238, 248), fg_a), "{s}", .{msg});
        ty += 34;
    }
}

fn captureSpecimen(app: *App, e: *const sim.Entity) !void {
    const sp = Specimen{
        .id = e.id,
        .society = e.society,
        .generation = e.generation,
        .lineage = e.lineage,
        .role = e.role(),
        .hybrid = e.hybrid,
        .captured_at = app.world.time,
        .age = e.age,
        .children = e.children,
        .kills = e.kills,
        .food_eaten = e.food_eaten,
        .distance_traveled = e.distance_traveled,
        .traits = e.genome.traits,
        .motor = e.genome.motor,
        .skills = e.skills,
        .cog = e.genome.cog,
        .fly_gain = try app.gpa.dupe(f32, e.genome.fly_gain),
    };
    if (app.specimen_count < max_specimens) {
        app.specimens[app.specimen_count] = sp;
        app.lab_active = app.specimen_count;
        app.specimen_count += 1;
    } else {
        app.gpa.free(app.specimens[0].fly_gain);
        std.mem.copyForwards(Specimen, app.specimens[0 .. max_specimens - 1], app.specimens[1..]);
        app.specimens[max_specimens - 1] = sp;
        app.lab_active = max_specimens - 1;
        if (app.lab_compare) |ci| app.lab_compare = if (ci > 0) ci - 1 else null;
    }
    app.show_lab = true;
    app.show_gens = false;
    app.show_exp = false;
}

fn drawLabPanel(app: *App, sw: f32) !void {
    const pw: f32 = 540;
    const px = (sw - pw) * 0.5;
    if (px < 322) return;
    const py: f32 = 52;
    const ph: f32 = 536;
    panel(px, py, pw, ph);

    var y = py + 12;
    text(px + 14, y, 15, rgb(235, 235, 245), "Specimen Lab - Capture, Compare & Experiment (T)", .{});
    y += 24;

    if (app.specimen_count == 0) {
        text(px + 14, y + 10, 12, rgb(175, 180, 195), "No specimens captured yet.", .{});
        text(px + 14, y + 32, 11, rgb(145, 150, 165), "Click any creature in the world and press Capture (or Shift+S) to save a snapshot.", .{});
        text(px + 14, y + 50, 11, rgb(145, 150, 165), "Capture early founders and later descendants to compare evolution side-by-side,", .{});
        text(px + 14, y + 68, 11, rgb(145, 150, 165), "tweak traits/skills, mutate cognitive brains, and release clones into the world.", .{});
        return;
    }

    if (app.lab_active >= app.specimen_count) app.lab_active = app.specimen_count - 1;

    // Specimen gallery tabs.
    var gx = px + 14;
    var gy = y;
    for (app.specimens[0..app.specimen_count], 0..) |sp, idx| {
        const bw: f32 = 82;
        if (gx + bw > px + pw - 14) {
            gx = px + 14;
            gy += 24;
        }
        const r = rect(gx, gy, bw, 20);
        const hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), r);
        const is_active = idx == app.lab_active;
        const is_cmp = app.lab_compare != null and app.lab_compare.? == idx;
        const bg = if (is_active) rgb(58, 72, 108) else if (is_cmp) rgb(44, 72, 66) else if (hover) rgb(46, 52, 74) else rgb(28, 32, 46);
        rl.DrawRectangleRounded(r, 0.35, 4, bg);
        if (is_active or is_cmp) {
            rl.DrawRectangleRoundedLinesEx(r, 0.35, 4, 1.2, if (is_active) rgb(140, 185, 255) else rgb(110, 230, 175));
        }
        text(r.x + 6, r.y + 3, 10, cladeColor(app.world.clades[@min(sp.society, app.world.clade_count - 1)]), "#{d} G{d}", .{ sp.id, sp.generation });
        if (hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) app.lab_active = idx;
        if (hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_RIGHT)) {
            app.lab_compare = if (is_cmp) null else idx;
        }
        gx += bw + 6;
    }
    y = gy + 28;

    const a = &app.specimens[app.lab_active];
    const cl = app.world.clades[@min(a.society, app.world.clade_count - 1)];
    text(px + 14, y, 16, cladeColor(cl), "{s} #{d}  (Gen {d}, {s})", .{ cl.name(), a.id, a.generation, @tagName(a.role) });
    text(px + 14, y + 20, 11, rgb(175, 180, 195), "lineage #{d}  kids {d}  kills {d}  food {d:.0}  travel {d:.0}u  brain {d}n/{d}s", .{
        a.lineage, a.children, a.kills, a.food_eaten, a.distance_traveled, a.cog.totalNeurons(), a.cog.activeSynapses(),
    });
    y += 38;

    // Action buttons row: Compare, Hybrid toggle, Mutate, Batch size, Release Clones.
    const cmp_r = rect(px + 14, y, 86, 22);
    const hyb_r = rect(px + 106, y, 76, 22);
    const mut_r = rect(px + 188, y, 74, 22);
    const qty_r = rect(px + 332, y, 64, 22);
    const rel_r = rect(px + 402, y, 124, 22);
    if (smallBtn(cmp_r, if (app.lab_compare != null) "Clear Cmp" else "Pin Cmp", rgb(44, 68, 66))) {
        app.lab_compare = if (app.lab_compare != null) null else app.lab_active;
    }
    if (smallBtn(hyb_r, if (a.hybrid) "Hybrid ON" else "Hybrid OFF", if (a.hybrid) rgb(88, 74, 30) else rgb(42, 46, 62))) {
        a.hybrid = !a.hybrid;
    }
    if (smallBtn(mut_r, "Mutate", rgb(76, 48, 92))) {
        const rng = app.world.prng.random();
        for (&a.traits) |*tv| tv.* = std.math.clamp(tv.* + rng.floatNorm(f32) * 0.12, 0, 1);
        _ = a.cog.addRandomSynapse(rng);
        if (rng.boolean()) _ = a.cog.addNeuron(rng);
    }
    const qty = release_batches[app.release_batch];
    var qbuf: [20]u8 = undefined;
    const qlabel = try std.fmt.bufPrint(&qbuf, "Qty: x{d}", .{qty});
    if (smallBtn(qty_r, qlabel, rgb(48, 56, 82))) {
        app.release_batch = (app.release_batch + 1) % release_batches.len;
    }
    var rbuf: [28]u8 = undefined;
    const rlabel = try std.fmt.bufPrint(&rbuf, "Release x{d}", .{qty});
    if (smallBtn(rel_r, rlabel, rgb(34, 82, 54))) {
        const home = app.world.territories[a.society].center();
        const safe = sim.bounds.inset(20);
        const rng = app.world.prng.random();
        var last_id: ?u32 = null;
        for (0..qty) |k| {
            const spread: f32 = if (qty == 1) 0 else 18 + @sqrt(@as(f32, @floatFromInt(k + 1))) * 14;
            const ang = rng.float(f32) * std.math.tau;
            const pos = sim.Vec2{
                .x = std.math.clamp(home.x + @cos(ang) * spread, safe.x, safe.x + safe.w),
                .y = std.math.clamp(home.y + @sin(ang) * spread, safe.y, safe.y + safe.h),
            };
            const spawned = try app.world.spawnClone(
                a.society,
                pos,
                a.traits,
                a.motor,
                a.cog,
                a.fly_gain,
                a.skills,
                a.generation,
                a.lineage,
                a.hybrid,
            );
            last_id = spawned.id;
        }
        if (last_id) |id| app.selected = id;
    }
    y += 30;

    const cmp: ?*const Specimen = if (app.lab_compare) |ci| (if (ci < app.specimen_count and ci != app.lab_active) &app.specimens[ci] else null) else null;
    if (cmp) |b| {
        text(px + 14, y, 11, rgb(115, 225, 185), "Comparing #{d} (G{d}) vs baseline #{d} (G{d}) - right-click any tab to switch", .{
            a.id, a.generation, b.id, b.generation,
        });
        y += 18;
    } else {
        text(px + 14, y, 11, rgb(140, 148, 165), "Use -/+ to tune features before clicking Release. Right-click another tab to compare.", .{});
        y += 18;
    }

    // Left column: Genes (with live -/+ tweakers and optional comparison delta).
    const col1_x = px + 14;
    const col2_x = px + 280;
    var y1 = y;
    text(col1_x, y1, 12, rgb(225, 225, 238), "Genes", .{});
    y1 += 17;
    for (&a.traits, 0..) |*tv, i| {
        const name = @tagName(@as(gen.Trait, @fromBackingInt(@intCast(i))));
        text(col1_x, y1 + 1, 11, rgb(175, 180, 195), "{s}", .{name});
        rl.DrawRectangleRec(rect(col1_x + 86, y1 + 4, 84, 7), rgb(34, 38, 52));
        rl.DrawRectangleRec(rect(col1_x + 86, y1 + 4, 84 * std.math.clamp(tv.*, 0, 1), 7), rgb(180, 160, 255));
        if (smallBtn(rect(col1_x + 174, y1 - 1, 18, 15), "-", rgb(42, 46, 64))) tv.* = std.math.clamp(tv.* - 0.1, 0, 1);
        if (smallBtn(rect(col1_x + 194, y1 - 1, 18, 15), "+", rgb(42, 46, 64))) tv.* = std.math.clamp(tv.* + 0.1, 0, 1);
        if (cmp) |b| {
            const delta = tv.* - b.traits[i];
            const dc = if (delta > 0.01) rgb(110, 235, 150) else if (delta < -0.01) rgb(250, 110, 100) else rgb(140, 145, 160);
            const sign: []const u8 = if (delta >= 0) "+" else "";
            text(col1_x + 216, y1 + 1, 10, dc, "{s}{d:.2}", .{ sign, delta });
        } else {
            text(col1_x + 216, y1 + 1, 10, rgb(155, 160, 175), "{d:.2}", .{tv.*});
        }
        y1 += 19;
    }

    // Right column: Learned skills + Cognitive brain graph.
    var y2 = y;
    text(col2_x, y2, 12, rgb(225, 225, 238), "Learned skills", .{});
    y2 += 17;
    for (&a.skills, 0..) |*sv, i| {
        const name = @tagName(@as(sim.Skill, @fromBackingInt(@intCast(i))));
        text(col2_x, y2 + 1, 11, rgb(175, 180, 195), "{s}", .{name});
        rl.DrawRectangleRec(rect(col2_x + 76, y2 + 4, 82, 7), rgb(34, 38, 52));
        rl.DrawRectangleRec(rect(col2_x + 76, y2 + 4, 82 * std.math.clamp(sv.*, 0, 1), 7), rgb(95, 220, 195));
        if (smallBtn(rect(col2_x + 162, y2 - 1, 18, 15), "-", rgb(42, 46, 64))) sv.* = std.math.clamp(sv.* - 0.1, 0, 1);
        if (smallBtn(rect(col2_x + 182, y2 - 1, 18, 15), "+", rgb(42, 46, 64))) sv.* = std.math.clamp(sv.* + 0.1, 0, 1);
        if (cmp) |b| {
            const delta = (sv.* - b.skills[i]) * 100;
            const dc = if (delta > 1) rgb(110, 235, 150) else if (delta < -1) rgb(250, 110, 100) else rgb(140, 145, 160);
            const sign: []const u8 = if (delta >= 0) "+" else "";
            text(col2_x + 204, y2 + 1, 10, dc, "{s}{d:.0}%", .{ sign, delta });
        } else {
            text(col2_x + 204, y2 + 1, 10, rgb(155, 160, 175), "{d:.0}%", .{sv.* * 100});
        }
        y2 += 19;
    }

    y2 += 10;
    text(col2_x, y2, 11, rgb(225, 225, 238), "Cognitive brain ({d}n, {d}s)", .{ a.cog.totalNeurons(), a.cog.activeSynapses() });
    y2 += 15;
    drawCognitiveGraph(&a.cog, col2_x, y2, 246, 72);
    if (cmp) |b| {
        const dn: i32 = @as(i32, @intCast(a.cog.totalNeurons())) - @as(i32, @intCast(b.cog.totalNeurons()));
        const ds: i32 = @as(i32, @intCast(a.cog.activeSynapses())) - @as(i32, @intCast(b.cog.activeSynapses()));
        const sn: []const u8 = if (dn >= 0) "+" else "";
        const ss: []const u8 = if (ds >= 0) "+" else "";
        text(col2_x, y2 + 76, 10, rgb(165, 210, 235), "vs baseline: {s}{d} neurons, {s}{d} synapses", .{ sn, dn, ss, ds });
    }
}

fn drawExpPanel(app: *App, sw: f32) !void {
    const w = &app.world;
    const pw: f32 = 524;
    const px = (sw - pw) * 0.5;
    if (px < 322) return;
    const py: f32 = 52;
    const ph: f32 = 432;
    panel(px, py, pw, ph);

    var y = py + 12;
    text(px + 14, y, 15, rgb(235, 235, 245), "Experiment Controls - Food, Weather, Hunting & Spawning (E)", .{});
    y += 22;
    text(px + 14, y, 11, rgb(175, 185, 200), "Food: {d}   Corpses: {d}   Built: {d}   Tools: {d}   Prey: {d}   Pred: {d}   Sick: {d}", .{
        w.foodCount(),
        w.corpseCount(),
        w.structureCount(),
        w.toolCount(),
        w.preyCount(),
        w.predatorCount(),
        w.sickCount(),
    });
    y += 24;

    // 1. Food Supply & Stress Tests
    text(px + 14, y, 12, rgb(225, 228, 240), "Food regrowth rate", .{});
    y += 18;
    const scarcities = [_]struct { sim.Scarcity, []const u8 }{
        .{ .feast, "Feast 5x" },
        .{ .abundant, "Abund 2x" },
        .{ .normal, "Normal" },
        .{ .scarce, "Scarce" },
        .{ .famine, "Famine" },
        .{ .none, "None 0x" },
    };
    var sx = px + 14;
    for (scarcities) |sc| {
        const active = w.scarcity == sc[0];
        const col = if (active) (if (sc[0] == .none) rgb(135, 42, 48) else if (sc[0] == .feast) rgb(40, 102, 62) else rgb(54, 72, 110)) else rgb(34, 38, 54);
        if (smallBtn(rect(sx, y, 78, 22), sc[1], col)) w.scarcity = sc[0];
        sx += 83;
    }
    y += 32;

    // Food drop amount selector
    text(px + 14, y + 3, 12, rgb(210, 215, 230), "Food drop amount:", .{});
    var fx = px + 144;
    for (food_batches, 0..) |amt, idx| {
        var fbuf: [16]u8 = undefined;
        const flab = try std.fmt.bufPrint(&fbuf, "+{d}", .{amt});
        const col = if (app.food_batch == idx) rgb(58, 76, 112) else rgb(34, 38, 54);
        if (smallBtn(rect(fx, y, 54, 21), flab, col)) app.food_batch = idx;
        fx += 60;
    }
    y += 28;

    const famt = food_batches[app.food_batch];
    const cluster_amt = @max(@as(usize, 10), famt / 3);
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    if (smallBtn(rect(px + 14, y, 124, 24), try std.fmt.bufPrint(&b1, "Food Flood (+{d})", .{famt}), rgb(34, 92, 58))) {
        try w.floodFood(famt);
    }
    if (smallBtn(rect(px + 144, y, 118, 24), try std.fmt.bufPrint(&b2, "Drop Here (+{d})", .{cluster_amt}), rgb(76, 72, 32))) {
        try w.dropFoodCluster(.{ .x = app.camera.target.x, .y = app.camera.target.y }, .universal, cluster_amt, 75);
    }
    if (smallBtn(rect(px + 268, y, 128, 24), "Clear All Food (0)", rgb(135, 38, 46))) {
        w.clearAllFood();
    }
    if (smallBtn(rect(px + 402, y, 108, 24), "Restore (+60)", rgb(44, 62, 92))) {
        w.scarcity = .normal;
        try w.floodFood(60);
    }
    y += 38;

    // 2. Weather & Environment
    text(px + 14, y, 12, rgb(225, 228, 240), "Weather phase (trigger immediately)", .{});
    y += 18;
    const phases = [_]struct { sim.WorldPhase, []const u8, rl.Color }{
        .{ .calm, "Calm (2:25)", rgb(42, 62, 96) },
        .{ .bloom, "Wild Bloom (1:30)", rgb(32, 90, 58) },
        .{ .storm, "Harsh Storm (1:05)", rgb(74, 52, 110) },
    };
    var wx = px + 14;
    for (phases) |ph_item| {
        const active = w.phase == ph_item[0];
        const col = if (active) ph_item[2] else rgb(34, 38, 54);
        if (smallBtn(rect(wx, y, 160, 24), ph_item[1], col)) w.setPhase(ph_item[0]);
        wx += 168;
    }
    y += 38;

    // 3. Population & Batch Release Spawner
    var total_pop: u32 = 0;
    for (0..w.clade_count) |si| total_pop += w.population(si);
    text(px + 14, y, 12, rgb(225, 228, 240), "Population release  ({d} alive across {d}/{d} clades)", .{ total_pop, w.activeCladeCount(), w.clade_count });
    y += 18;
    text(px + 14, y + 3, 11, rgb(180, 185, 200), "Release amount:", .{});
    var bx = px + 124;
    for (release_batches, 0..) |cnt, idx| {
        var rbuf: [16]u8 = undefined;
        const rlab = try std.fmt.bufPrint(&rbuf, "x{d}", .{cnt});
        const col = if (app.release_batch == idx) rgb(58, 76, 112) else rgb(34, 38, 54);
        if (smallBtn(rect(bx, y, 48, 21), rlab, col)) app.release_batch = idx;
        bx += 54;
    }
    y += 28;

    const rqty = release_batches[app.release_batch];
    var s0: [28]u8 = undefined;
    var s1: [28]u8 = undefined;
    var s2: [28]u8 = undefined;
    var s3: [28]u8 = undefined;
    if (smallBtn(rect(px + 14, y, 120, 24), try std.fmt.bufPrint(&s0, "+Triangles (+{d})", .{rqty}), rgb(110, 42, 42))) {
        _ = try w.spawnRandomBatch(0, rqty);
    }
    if (smallBtn(rect(px + 140, y, 114, 24), try std.fmt.bufPrint(&s1, "+Circles (+{d})", .{rqty}), rgb(38, 62, 112))) {
        _ = try w.spawnRandomBatch(1, rqty);
    }
    if (smallBtn(rect(px + 260, y, 116, 24), try std.fmt.bufPrint(&s2, "+Squares (+{d})", .{rqty}), rgb(36, 92, 54))) {
        _ = try w.spawnRandomBatch(2, rqty);
    }
    if (smallBtn(rect(px + 382, y, 128, 24), try std.fmt.bufPrint(&s3, "+All (+{d} each)", .{rqty}), rgb(54, 60, 84))) {
        for (0..w.clade_count) |si| _ = try w.spawnRandomBatch(@intCast(si), rqty);
    }
    y += 34;

    // 4. Knowledge, Tools, Wild Prey, Outbreaks & Speciation
    text(px + 14, y, 12, rgb(225, 228, 240), "Tools, wildlife, immunity, speciation & brain mode", .{});
    y += 18;
    if (smallBtn(rect(px + 14, y, 108, 24), "Spawn Prey (+3)", rgb(104, 72, 34))) {
        try w.spawnPrey(3);
    }
    if (smallBtn(rect(px + 128, y, 122, 24), "Spawn Predator", rgb(135, 32, 62))) {
        try w.spawnPredators(1);
    }
    if (smallBtn(rect(px + 256, y, 122, 24), "Trigger Outbreak", rgb(92, 108, 32))) {
        _ = w.triggerOutbreak();
    }
    if (smallBtn(rect(px + 384, y, 124, 24), "Inspire Pioneers", rgb(44, 76, 86))) {
        w.inspirePioneers();
    }
    y += 32;
    const mode_label = if (w.pure_neural) "Brain: PURE NEURAL (0 autopilot)" else "Brain: Assisted (steerTo helpers)";
    const mode_col = if (w.pure_neural) rgb(72, 46, 114) else rgb(44, 56, 82);
    if (smallBtn(rect(px + 14, y, 252, 24), mode_label, mode_col)) {
        w.pure_neural = !w.pure_neural;
    }
    if (smallBtn(rect(px + 274, y, 234, 24), "Seed New Tribe (+10, dynamic clade)", rgb(32, 92, 86))) {
        _ = try w.spawnNewClade(10);
    }
    y += 30;
    text(px + 14, y, 10, rgb(140, 148, 165), "Pure Neural removes all steerTo autopilots: movement & calls come 100% from FlyWire + evolved recurrent cortex.", .{});
}

fn smallBtn(r: rl.Rectangle, label: []const u8, base_col: rl.Color) bool {
    const hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), r);
    const col = if (hover) rgb(@min(255, @as(u16, base_col.r) + 22), @min(255, @as(u16, base_col.g) + 22), @min(255, @as(u16, base_col.b) + 22)) else base_col;
    rl.DrawRectangleRounded(r, 0.35, 4, col);
    text(r.x + 5, r.y + 2, 10, rgb(230, 235, 245), "{s}", .{label});
    return hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT);
}

fn drawGenerationsPanel(app: *App, sw: f32) void {
    const w = &app.world;
    const pw: f32 = 460;
    const px = (sw - pw) * 0.5;
    if (px < 322) return;
    const py: f32 = 52;
    const ph: f32 = 424;
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
            rl.DrawCircleV(.{ .x = px + 20, .y = y + 6 }, 3.8, eventColor(w, ev));
            var buf: [128]u8 = undefined;
            const msg = formatEvent(w, &buf, ev);
            text(px + 30, y, 11, rgb(200, 205, 220), "{s}", .{msg});
            y += 16;
        }
    }

    y += 8;
    // 2. Emergent Society Roles (top 3 active clades)
    text(px + 14, y, 12, rgb(210, 215, 230), "Emergent roles ({d} active / {d} clades)", .{ w.activeCladeCount(), w.clade_count });
    y += 18;
    var g_order: [sim.max_societies]usize = undefined;
    for (0..w.clade_count) |si| g_order[si] = si;
    if (w.clade_count > 3) {
        for (0..w.clade_count) |a| {
            var best = a;
            for (a + 1..w.clade_count) |b| {
                if (w.population(g_order[b]) > w.population(g_order[best])) best = b;
            }
            const tmp = g_order[a];
            g_order[a] = g_order[best];
            g_order[best] = tmp;
        }
    }
    const show_clades = @min(w.clade_count, 3);
    for (g_order[0..show_clades]) |si| {
        const cl = w.clades[si];
        var counts: [sim.role_count]u32 = @splat(0);
        var avg_sk: [sim.skill_count]f32 = @splat(0);
        var n: f32 = 0;
        for (w.entities.items) |e| {
            if (e.dead != null or e.society != si) continue;
            n += 1;
            counts[@backingInt(e.role())] += 1;
            for (&avg_sk, e.skills) |*a, v| a.* += v;
        }
        const d = @max(n, 1);
        text(px + 14, y, 12, cladeColor(cl), "{s}", .{cl.name()});
        text(px + 92, y, 11, rgb(185, 190, 205), "for {d}  sct {d}  grd {d}  car {d}  bld {d}  hnt {d}  eld {d}", .{
            counts[@backingInt(sim.Role.forager)],
            counts[@backingInt(sim.Role.scout)],
            counts[@backingInt(sim.Role.guard)],
            counts[@backingInt(sim.Role.caretaker)],
            counts[@backingInt(sim.Role.builder)],
            counts[@backingInt(sim.Role.hunter)],
            counts[@backingInt(sim.Role.elder)],
        });
        y += 15;
        text(px + 92, y, 10, rgb(140, 148, 165), "skills: for {d:.0}% nav {d:.0}% cmb {d:.0}% car {d:.0}% bld {d:.0}% tool {d:.0}%", .{
            avg_sk[0] / d * 100, avg_sk[1] / d * 100, avg_sk[2] / d * 100, avg_sk[3] / d * 100, avg_sk[4] / d * 100, avg_sk[5] / d * 100,
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

    // 4. Emergent Dialects (3-channel vocal vectors mapped to RGB swatches + food-vs-threat separation)
    y += 6;
    text(px + 14, y, 11, rgb(205, 215, 235), "Emergent dialects (divergence {d:.2})", .{w.dialectDivergence()});
    y += 16;
    for (g_order[0..show_clades], 0..) |si, col_i| {
        const cl = w.clades[si];
        const st = w.stats[si];
        const dx = px + 14 + @as(f32, @floatFromInt(col_i)) * 146;
        rl.DrawCircleV(.{ .x = dx + 6, .y = y + 5 }, 4.5, vocalColor(st.vocal_mean));
        text(dx + 15, y, 10, cladeColor(cl), "{s}", .{cl.name()});
        text(dx + 72, y, 10, rgb(165, 175, 195), "sep {d:.2}", .{st.vocalContextSep()});
    }
}

fn drawPhaseBadge(x: f32, y: f32, p: sim.WorldPhase, rem: f32) void {
    const label, const bg, const fg = switch (p) {
        .calm => .{ "CALM", rgb(34, 44, 66), rgb(165, 195, 235) },
        .bloom => .{ "BLOOM", rgb(26, 74, 50), rgb(120, 240, 165) },
        .storm => .{ "STORM", rgb(56, 42, 86), rgb(190, 170, 255) },
    };
    const rmins: u32 = @intFromFloat(@max(0, rem) / 60);
    const rsecs: u32 = @intFromFloat(@mod(@max(0, rem), 60));
    rl.DrawRectangleRounded(rect(x, y, 92, 17), 0.4, 4, bg);
    text(x + 7, y + 3, 10, fg, "{s} {d}:{d:0>2}", .{ label, rmins, rsecs });
}

fn formatEvent(w: *const World, buf: []u8, ev: sim.WorldEvent) []const u8 {
    const mins: u32 = @intFromFloat(ev.time / 60);
    const secs: u32 = @intFromFloat(@mod(ev.time, 60));
    const name = w.clades[@min(ev.society, w.clade_count - 1)].name();
    return switch (ev.kind) {
        .endangered => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} endangered ({d} left)", .{ mins, secs, name, ev.value }),
        .critical => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} near extinction ({d} left!)", .{ mins, secs, name, ev.value }),
        .extinct => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} went extinct (reached Gen {d})", .{ mins, secs, name, ev.value }),
        .recovered => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} recovered ({d} strong)", .{ mins, secs, name, ev.value }),
        .boom => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} booming ({d} population)", .{ mins, secs, name, ev.value }),
        .milestone_gen => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} reached Generation {d}", .{ mins, secs, name, ev.value }),
        .first_hybrid => std.fmt.bufPrint(buf, "{d}:{d:0>2}  First {s} hybrid born (Gen {d})", .{ mins, secs, name, ev.value }),
        .hybrid_majority => std.fmt.bufPrint(buf, "{d}:{d:0>2}  Hybrids now lead {s} ({d} pop)", .{ mins, secs, name, ev.value }),
        .territory_clash => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} & {s} contesting territory!", .{ mins, secs, name, w.clades[@min(ev.value, w.clade_count - 1)].name() }),
        .cannibalism => std.fmt.bufPrint(buf, "{d}:{d:0>2}  Cannibalism emerged in {s} ({d} kills)!", .{ mins, secs, name, ev.value }),
        .tool_discovered => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} discovered tool-making!", .{ mins, secs, name }),
        .building_discovered => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} built their first {s}!", .{ mins, secs, name, if (ev.value == 0) "shelter" else "food cache" }),
        .predator_slain => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} slew an Apex Predator ({d} total)!", .{ mins, secs, name, ev.value }),
        .cache_raided => std.fmt.bufPrint(buf, "{d}:{d:0>2}  {s} raided a {s} food cache!", .{ mins, secs, w.clades[@min(ev.value, w.clade_count - 1)].name(), name }),
        .species_diverged => std.fmt.bufPrint(buf, "{d}:{d:0>2}  New species diverged: {s} (Gen {d})!", .{ mins, secs, name, ev.value }),
        .outbreak => std.fmt.bufPrint(buf, "{d}:{d:0>2}  Disease outbreak in {s} (strain #{d})!", .{ mins, secs, name, ev.value }),
        .trade_emerged => std.fmt.bufPrint(buf, "{d}:{d:0>2}  Reciprocal trade emerged in {s} ({d} exchanges)!", .{ mins, secs, name, ev.value }),
        .world_bloom => std.fmt.bufPrint(buf, "{d}:{d:0>2}  Wild bloom - abundant food growth", .{ mins, secs }),
        .world_storm => std.fmt.bufPrint(buf, "{d}:{d:0>2}  Harsh storm sweeping the frontier", .{ mins, secs }),
    } catch "";
}

fn eventColor(w: *const World, ev: sim.WorldEvent) rl.Color {
    return switch (ev.kind) {
        .endangered, .territory_clash, .cache_raided => rgb(250, 185, 70),
        .critical, .extinct => rgb(255, 85, 75),
        .cannibalism => rgb(255, 75, 125),
        .tool_discovered, .building_discovered, .predator_slain => rgb(110, 230, 235),
        .species_diverged => rgb(90, 245, 220),
        .outbreak => rgb(185, 235, 75),
        .trade_emerged => rgb(255, 215, 95),
        .recovered, .boom, .world_bloom => rgb(100, 235, 145),
        .milestone_gen => cladeColor(w.clades[@min(ev.society, w.clade_count - 1)]),
        .first_hybrid, .hybrid_majority => rgb(255, 220, 70),
        .world_storm => rgb(175, 155, 255),
    };
}

fn drawKey(app: *App, x: f32, top: f32) void {
    const w: f32 = 300;
    const h: f32 = 386;
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
            .diamond, .pentagon, .hexagon => {
                rl.DrawPoly(c, 6, 7.0, 0, col);
                rl.DrawPolyLinesEx(c, 6, 7.0, 0, 1, rgb(0, 0, 0));
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
    text(x + 34, y, 11, rgb(175, 180, 195), "Corpse (rotting)", .{});
    rl.DrawCircleV(.{ .x = x + 158, .y = y + 6 }, 4.5, foodColor(.herb));
    text(x + 170, y, 11, rgb(210, 165, 250), "Herb (medicine)", .{});
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
    y += 22;

    text(x + 12, y, 12, rgb(215, 220, 232), "Materials, tools & structures", .{});
    y += 17;
    rl.DrawRectangleRounded(rect(x + 17, y + 3, 10, 6), 0.35, 4, rgb(176, 122, 68));
    text(x + 34, y, 11, rgb(175, 180, 195), "Wood / Basket", .{});
    rl.DrawPoly(.{ .x = x + 158, .y = y + 6 }, 5, 5.5, 18, rgb(156, 168, 186));
    text(x + 170, y, 11, rgb(175, 180, 195), "Stone / Spear", .{});
    y += 17;
    rl.DrawPolyLinesEx(.{ .x = x + 22, .y = y + 6 }, 6, 6, 30, 1.4, rgb(135, 210, 255));
    text(x + 34, y, 11, rgb(175, 180, 195), "Shelter / Cache", .{});
    rl.DrawPoly(.{ .x = x + 158, .y = y + 6 }, 6, 6, 0, rgb(212, 152, 72));
    text(x + 170, y, 11, rgb(175, 180, 195), "Wild Prey", .{});
    y += 17;
    rl.DrawPoly(.{ .x = x + 22, .y = y + 6 }, 4, 6.5, 0, rgb(205, 38, 72));
    text(x + 34, y, 11, rgb(245, 145, 165), "Apex Predator (hunts outside shelters)", .{});
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
    for (w.history[0..w.history_count]) |row| for (row[0..w.clade_count]) |v| {
        peak = @max(peak, @as(f32, @floatFromInt(v)));
    };
    const step = width / @as(f32, @floatFromInt(w.history_count - 1));
    for (0..w.clade_count) |si| {
        const col = cladeColor(w.clades[si]);
        for (1..w.history_count) |i| {
            const a = w.history[i - 1][si];
            const b = w.history[i][si];
            if (a == 0 and b == 0 and si >= sim.society_count) continue;
            rl.DrawLineEx(
                .{ .x = x + step * @as(f32, @floatFromInt(i - 1)), .y = y + height - height * @as(f32, @floatFromInt(a)) / peak },
                .{ .x = x + step * @as(f32, @floatFromInt(i)), .y = y + height - height * @as(f32, @floatFromInt(b)) / peak },
                1.5,
                col,
            );
        }
    }
    text(x + 4, y + 2, 10, rgb(120, 125, 140), "population (peak {d:.0})", .{peak});
}

fn drawInspector(app: *App, e: *const sim.Entity) !void {
    const cl = app.world.clades[@min(e.society, app.world.clade_count - 1)];
    const sh: f32 = @floatFromInt(rl.GetScreenHeight());
    const x: f32 = 12;
    const top_y: f32 = 114;
    const max_h = @max(@as(f32, 460), sh - 74 - top_y);
    const want_h: f32 = if (app.show_brain) 680 else 518;
    const h = @min(want_h, max_h);
    var y = top_y;
    panel(x, y, 300, h);
    y += 7;
    var id_buf: [32]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{s} #{d}", .{ cl.name(), e.id });
    text(x + 12, y, 16, cladeColor(cl), "{s}", .{id_str});
    const role_tag = @tagName(e.role());
    const stage_tag = @tagName(e.stage());
    const role_x = x + 18 + @as(f32, @floatFromInt(id_str.len)) * 8.2;
    if (std.mem.eql(u8, role_tag, stage_tag)) {
        text(role_x, y + 4, 11, rgb(170, 210, 240), "{s}", .{role_tag});
    } else {
        text(role_x, y + 4, 11, rgb(170, 210, 240), "{s} ({s})", .{ role_tag, stage_tag });
    }
    if (smallBtn(rect(x + 232, y + 1, 56, 17), "Capture", rgb(44, 68, 86))) try captureSpecimen(app, e);
    y += 21;
    text(x + 12, y, 11, rgb(190, 195, 210), "gen {d}  lin #{d}  age {d:.1}/{d:.0}m  kids {d}  kills {d}", .{ e.generation, e.lineage, e.age / 60, e.lifespan / 60, e.children, e.kills });
    if (e.hybrid) text(x + 258, y + 1, 10, rgb(255, 220, 60), "HYB", .{});
    y += 14;
    const suffix: []const u8 = if (e.cannibal_target and e.action == .fight)
        " (hunting kin)"
    else if (e.recalling) |rk| switch (rk) {
        .food => " (recalling food)",
        .material => " (recalling quarry)",
        .shelter => " (recalling shelter)",
        .danger => " (avoiding danger)",
        .prey => " (tracking prey)",
    } else if (e.in_shelter)
        " (in shelter)"
    else if (e.resting)
        " (resting)"
    else if (e.feeding)
        " (feeding)"
    else if (e.heard_kind) |hk| switch (hk) {
        .food_found => " (heard food)",
        .danger_call => " (heard danger)",
        .storm_rally => " (heard rally)",
        .mate_call => " (heard mate)",
    } else if (app.world.phase == .storm and e.huddled)
        " (huddled)"
    else if (e.visible_food != null)
        " (food in sight)"
    else if (e.explore_target != null)
        " (exploring)"
    else
        "";
    text(x + 12, y, 11, rgb(190, 195, 210), "parents #{d} & #{d}   action: {s}{s}", .{ e.parents[0], e.parents[1], @tagName(e.action), suffix });
    y += 14;
    text(x + 12, y, 11, rgb(175, 210, 220), "gear: {s} ({d:.0}%)   carrying: {s}", .{ @tagName(e.tool), e.tool_durability, @tagName(e.carrying) });
    y += 14;
    text(x + 12, y, 10, rgb(170, 200, 185), "diet M/P/X {d:.0}/{d:.0}/{d:.0}%   size x{d:.2} ({s})", .{
        e.genome.digest[0] * 100, e.genome.digest[1] * 100, e.genome.digest[2] * 100, e.genome.body_scale, @tagName(cl.shape),
    });
    y += 13;
    if (e.infection) |inf| {
        text(x + 12, y, 10, rgb(195, 240, 85), "SICK {d:.0}% (strain #{d}, vir {d:.2})  ab {d}/4", .{
            @min(100, inf.load * 100), inf.strain_id, inf.virulence, e.antibodyCount(),
        });
    } else {
        text(x + 12, y, 10, rgb(145, 215, 175), "health: OK  antibodies {d}/4{s}", .{
            e.antibodyCount(), if (e.herb_boost > 0) "  (herb boost)" else "",
        });
    }
    y += 13;
    bar(x + 12, y, "energy", e.energy / sim.max_energy, energyColor(e.energy));
    y += 16;

    text(x + 12, y, 12, rgb(235, 235, 245), "Senses -> fly circuit", .{});
    y += 14;
    const sense = e.senses;
    bar2(x + 12, y, "odour L/R", sense.attr_L, sense.attr_R, rgb(120, 220, 160));
    y += 13;
    bar2(x + 12, y, "alarm L/R", sense.alarm_L, sense.alarm_R, rgb(255, 140, 60));
    y += 13;
    bar2(x + 12, y, "sugar/bitter", sense.sugar, sense.bitter, rgb(240, 220, 120));
    y += 16;

    text(x + 12, y, 12, rgb(235, 235, 245), "Fly motor output", .{});
    y += 14;
    const m = e.motor;
    bar2(x + 12, y, "DNa01/02 L/R", m.turn_L * 5, m.turn_R * 5, rgb(140, 180, 255));
    y += 13;
    bar(x + 12, y, "DNp09 walk", m.fwd, rgb(140, 180, 255));
    y += 13;
    bar(x + 12, y, "MDN back", m.back, rgb(140, 180, 255));
    y += 13;
    bar(x + 12, y, "giant fibre", m.escape, rgb(140, 180, 255));
    y += 13;
    bar(x + 12, y, "MN9 feed", m.feed, rgb(140, 180, 255));
    y += 16;

    text(x + 12, y, 12, rgb(235, 235, 245), "Learned skills (passed down)", .{});
    y += 14;
    for (e.skills, 0..) |v, i| {
        bar(x + 12, y, @tagName(@as(sim.Skill, @fromBackingInt(@intCast(i)))), v, rgb(95, 220, 195));
        y += 12;
    }
    y += 4;

    text(x + 12, y, 12, rgb(235, 235, 245), "Genes", .{});
    y += 14;
    for (e.genome.traits, 0..) |v, i| {
        bar(x + 12, y, @tagName(@as(gen.Trait, @fromBackingInt(@intCast(i)))), v, rgb(180, 160, 255));
        y += 12;
    }

    if (app.show_brain) {
        y += 4;
        const cog = &e.genome.cog;
        text(x + 12, y, 11, rgb(235, 235, 245), "Mind ({d}n, {d}s, {d} rec, +{d} grown)", .{
            cog.totalNeurons(), cog.activeSynapses(), cog.recurrentSynapses(), cog.lifetime_rewires,
        });
        y += 13;
        text(x + 12, y, 10, rgb(165, 195, 220), "DA {d:.2}  NA {d:.2}  5HT {d:.2}   mem {d}/6  bonds {d}", .{
            cog.dopamine, cog.noradrenaline, cog.serotonin, e.activeMemories(), e.bondCount(),
        });
        y += 12;
        text(x + 12, y, 10, rgb(185, 165, 225), "Hebb A {d:.2} lr {d:.3}  t {d:.2} s {d:.2} m {d:.2} v {d:.2}", .{
            cog.hebb_a, cog.hebb_lr, cog.turn_out, cog.speed_out, cog.mod_out, cog.call_out,
        });
        // Live acoustic voice swatch (left dot) and heard vocalization swatch (right dot if hearing sound).
        rl.DrawCircleV(.{ .x = x + 272, .y = y + 5 }, 4.0, vocalColor(cog.call_f));
        if (e.heard_timer > 0 and e.heard_vol > 0.05) {
            rl.DrawCircleV(.{ .x = x + 283, .y = y + 5 }, 4.0, vocalColor(e.heard_vec));
            rl.DrawCircleLinesV(.{ .x = x + 283, .y = y + 5 }, 5.0, rgb(235, 240, 250));
        }
        y += 13;
        drawCognitiveGraph(cog, x + 12, y, 276, 46);
        y += 50;

        const c = app.world.circuit;
        const rem_h = top_y + h - y - 16;
        if (rem_h >= 24) {
            text(x + 12, y, 11, rgb(235, 235, 245), "FlyWire brainstem ({d} neurons, {d} synapses)", .{ c.neurons, c.connections() });
            y += 13;
            const cols: usize = 78;
            const rows: f32 = @ceil(@as(f32, @floatFromInt(e.brain.r.len)) / @as(f32, @floatFromInt(cols)));
            const cell = @min(@as(f32, 3.5), @max(1.8, (top_y + h - y - 6) / rows));
            for (e.brain.r, 0..) |r, i| {
                const cx = x + 12 + @as(f32, @floatFromInt(i % cols)) * cell;
                const cy = y + @as(f32, @floatFromInt(i / cols)) * cell;
                const v: u8 = @intFromFloat(std.math.clamp(r, 0, 1) * 255);
                rl.DrawRectangleRec(rect(cx, cy, @max(1.0, cell - 0.6), @max(1.0, cell - 0.6)), .{ .r = v, .g = @intFromFloat(@as(f32, @floatFromInt(v)) * 0.7), .b = 40 + v / 3, .a = 255 });
            }
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

    // Synapses: green = excitatory, red = inhibitory, violet = recurrent working-memory loop.
    for (cog.synapses[0..cog.synapse_count]) |s| {
        if (!s.active) continue;
        const mag = std.math.clamp(@abs(s.weight) / 2.0, 0.15, 1.0);
        const alpha: u8 = @intFromFloat(mag * 150);
        if (s.isRecurrent()) {
            const rcol = withAlpha(rgb(190, 125, 255), @min(220, @as(u16, alpha) + 40));
            if (s.from == s.to) {
                rl.DrawCircleLinesV(.{ .x = pos[s.from].x, .y = pos[s.from].y - 3.5 }, 4.2, rcol);
            } else {
                rl.DrawLineEx(pos[s.from], pos[s.to], 1.2 + 0.6 * mag, rcol);
            }
        } else {
            const col = if (s.weight >= 0) withAlpha(rgb(90, 225, 150), alpha) else withAlpha(rgb(245, 95, 95), alpha);
            rl.DrawLineEx(pos[s.from], pos[s.to], 0.9 + 0.6 * mag, col);
        }
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
        const col: rl.Color = if (oi < gen.action_outputs)
            actionColor(@fromBackingInt(@intCast(oi)))
        else switch (oi - gen.action_outputs) {
            0 => rgb(255, 215, 90), // turn_out
            1 => rgb(95, 235, 255), // speed_out
            2 => rgb(235, 115, 255), // mod_out (evolved neuromodulator)
            3 => rgb(115, 245, 175), // call_out (volume/drive)
            4 => rgb(255, 110, 110), // call_f0
            5 => rgb(110, 245, 145), // call_f1
            else => rgb(110, 175, 255), // call_f2
        };
        rl.DrawCircleV(pos[idx], 3.0, withAlpha(col, 110 + @as(u8, @intFromFloat(a * 145))));
    }
}

fn setStatusNote(app: *App, msg: []const u8) void {
    const n = @min(msg.len, app.status_note.len);
    @memcpy(app.status_note[0..n], msg[0..n]);
    app.status_note_len = n;
    app.status_note_timer = 4.0;
}

fn setDirectorCaption(app: *App, comptime fmt: []const u8, args: anytype) void {
    if (std.fmt.bufPrint(&app.director_caption, fmt, args)) |slice| {
        app.director_caption_len = slice.len;
    } else |_| {}
}

/// Nature-documentary Auto-Director camera: smoothly pans to live high-drama hotspots
/// (reciprocal trades, apex predator chases, clashes, outbreaks, builders, thriving settlements).
fn updateDirector(app: *App, frame_dt: f32) void {
    const w = &app.world;
    app.director_timer -= frame_dt;
    if (app.director_timer <= 0) {
        app.director_timer = 6.5;
        if (w.trade_arc_count > 0) {
            const arc = w.trade_arcs[w.trade_arc_count - 1];
            app.director_target = .{ .x = (arc.from.x + arc.to.x) * 0.5, .y = (arc.from.y + arc.to.y) * 0.5 };
            app.director_zoom = 1.95;
            setDirectorCaption(app, "{s}", .{if (arc.reciprocal) "Reciprocal barter exchange!" else "Emergent gift transfer"});
        } else blk: {
            // Look for active apex predator hunting near creatures.
            for (w.predators.items) |pd| {
                if (pd.hp > 0 and pd.sated_timer <= 0) {
                    app.director_target = pd.pos;
                    app.director_zoom = 1.55;
                    setDirectorCaption(app, "Apex predator stalking the frontier", .{});
                    break :blk;
                }
            }
            // Look for active outbreak patient or clash/builder.
            for (w.entities.items) |e| {
                if (e.dead != null) continue;
                if (e.infection != null) {
                    app.director_target = e.pos;
                    app.director_zoom = 1.85;
                    setDirectorCaption(app, "Pathogen outbreak in {s} - immune defense active", .{w.clades[@min(e.society, w.clade_count - 1)].name()});
                    break :blk;
                }
            }
            for (w.entities.items) |e| {
                if (e.dead != null) continue;
                if (e.action == .fight and e.enemy != null) {
                    app.director_target = e.pos;
                    app.director_zoom = 1.75;
                    setDirectorCaption(app, "Territorial clash involving {s}", .{w.clades[@min(e.society, w.clade_count - 1)].name()});
                    break :blk;
                }
            }
            // Fallback: frame the most active clade's living center.
            var best_si: usize = 0;
            var best_pop: u32 = 0;
            for (0..w.clade_count) |si| {
                const p = w.population(si);
                if (p > best_pop) {
                    best_pop = p;
                    best_si = si;
                }
            }
            app.director_target = w.territories[best_si].center();
            app.director_zoom = 1.15;
            setDirectorCaption(app, "Thriving settlement: {s} ({d} alive)", .{ w.clades[best_si].name(), best_pop });
        }
    }
    const alpha = 1.0 - @exp(-2.6 * frame_dt);
    app.camera.target.x += (app.director_target.x - app.camera.target.x) * alpha;
    app.camera.target.y += (app.director_target.y - app.camera.target.y) * alpha;
    app.camera.zoom += (app.director_zoom - app.camera.zoom) * alpha;
    clampCamera(&app.camera);
}

// ---------------------------------------------------------------- helpers

fn v2(p: sim.Vec2) rl.Vector2 {
    return .{ .x = p.x, .y = p.y };
}

fn societyColor(s: sim.Society) rl.Color {
    return rgb(s.color[0], s.color[1], s.color[2]);
}

fn cladeColor(c: sim.Clade) rl.Color {
    return rgb(c.color[0], c.color[1], c.color[2]);
}

/// Map a 3-channel arbitrary vocal token in [-1, +1]^3 to a vivid RGB acoustic color.
fn vocalColor(vec: [3]f32) rl.Color {
    const r: u8 = @intFromFloat(std.math.clamp((vec[0] * 0.5 + 0.5) * 180 + 75, 75, 255));
    const g: u8 = @intFromFloat(std.math.clamp((vec[1] * 0.5 + 0.5) * 180 + 75, 75, 255));
    const b: u8 = @intFromFloat(std.math.clamp((vec[2] * 0.5 + 0.5) * 180 + 75, 75, 255));
    return rgb(r, g, b);
}

fn foodColor(t: sim.FoodType) rl.Color {
    return switch (t) {
        .meat => rgb(255, 107, 107),
        .plant => rgb(78, 205, 160),
        .mineral => rgb(149, 200, 240),
        .universal => rgb(255, 235, 59),
        .herb => rgb(195, 115, 255),
    };
}

fn actionColor(a: gen.SocialAction) rl.Color {
    return switch (a) {
        .forage => rgb(200, 200, 200),
        .fight => rgb(255, 70, 70),
        .mate => rgb(255, 120, 220),
        .socialize => rgb(120, 200, 255),
        .flee => rgb(255, 200, 80),
        .gather => rgb(195, 150, 95),
        .craft_tool => rgb(140, 235, 235),
        .build => rgb(145, 225, 130),
        .offer => rgb(255, 215, 95),
    };
}

fn energyColor(energy: f32) rl.Color {
    return if (energy > 60) rgb(80, 220, 100) else if (energy > 30) rgb(240, 210, 60) else rgb(240, 70, 60);
}
