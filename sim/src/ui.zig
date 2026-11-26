//! Drawing helpers and camera controls shared by the views.

const std = @import("std");
const rl = @import("raylib");

pub const Options = struct {
    seed: ?u64 = null,
    /// Save a screenshot to this file and exit.
    shot: ?[:0]const u8 = null,
    /// Simulated seconds to run before the screenshot.
    warmup: u32 = 90,
    zoom: ?f32 = null,
    /// Optional CSV output path for run telemetry.
    out: ?[:0]const u8 = null,
    /// Optional binary `.esav` snapshot to load on startup.
    load_path: ?[:0]const u8 = null,
    /// Optional binary `.esav` snapshot to save on exit / headless finish.
    save_path: ?[:0]const u8 = null,
};

pub const speeds = [_]u32{ 1, 2, 4, 8, 16, 32, 64 };

// Panels drawn last frame, so clicks on the HUD don't fall through to the map.
var panels: [32]rl.Rectangle = undefined;
var panel_count: usize = 0;
var last_panels: [32]rl.Rectangle = undefined;
var last_count: usize = 0;

var ui_font: rl.Font = undefined;
var custom_font: bool = false;

pub fn initFont() void {
    const candidates = [_][*:0]const u8{
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    };
    for (candidates) |path| {
        if (!rl.FileExists(path)) continue;
        var f = rl.LoadFontEx(path, 64, null, 0);
        if (rl.IsFontValid(f) and f.texture.id != 0) {
            rl.GenTextureMipmaps(&f.texture);
            rl.SetTextureFilter(f.texture, rl.TEXTURE_FILTER_TRILINEAR);
            ui_font = f;
            custom_font = true;
            return;
        }
    }
    ui_font = rl.GetFontDefault();
    custom_font = false;
}

pub fn deinitFont() void {
    if (custom_font) {
        rl.UnloadFont(ui_font);
        custom_font = false;
    }
}

pub fn beginFrame() void {
    last_panels = panels;
    last_count = panel_count;
    panel_count = 0;
}

pub fn mouseOverPanel() bool {
    const m = rl.GetMousePosition();
    for (last_panels[0..last_count]) |r| {
        if (rl.CheckCollisionPointRec(m, r)) return true;
    }
    return false;
}

/// WASD/arrows and right-drag pan, wheel zooms toward the cursor.
/// Returns true if the user dragged the view.
pub fn panZoom(cam: *rl.Camera2D, min_zoom: f32, max_zoom: f32) bool {
    const pan = 600 / cam.zoom * rl.GetFrameTime();
    if (rl.IsKeyDown(rl.KEY_W) or rl.IsKeyDown(rl.KEY_UP)) cam.target.y -= pan;
    if (rl.IsKeyDown(rl.KEY_S) or rl.IsKeyDown(rl.KEY_DOWN)) cam.target.y += pan;
    if (rl.IsKeyDown(rl.KEY_A) or rl.IsKeyDown(rl.KEY_LEFT)) cam.target.x -= pan;
    if (rl.IsKeyDown(rl.KEY_D) or rl.IsKeyDown(rl.KEY_RIGHT)) cam.target.x += pan;
    var dragged = false;
    if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_RIGHT) or rl.IsMouseButtonDown(rl.MOUSE_BUTTON_MIDDLE)) {
        const d = rl.GetMouseDelta();
        cam.target.x -= d.x / cam.zoom;
        cam.target.y -= d.y / cam.zoom;
        dragged = true;
    }
    const wheel = rl.GetMouseWheelMove();
    if (wheel != 0) {
        const mouse = rl.GetMousePosition();
        const before = rl.GetScreenToWorld2D(mouse, cam.*);
        cam.zoom = std.math.clamp(cam.zoom * @exp(wheel * 0.1), min_zoom, max_zoom);
        const after = rl.GetScreenToWorld2D(mouse, cam.*);
        cam.target.x += before.x - after.x;
        cam.target.y += before.y - after.y;
    }
    cam.offset = .{ .x = screenW() / 2, .y = screenH() / 2 };
    return dragged;
}

pub fn screenW() f32 {
    return @floatFromInt(rl.GetScreenWidth());
}

pub fn screenH() f32 {
    return @floatFromInt(rl.GetScreenHeight());
}

pub fn text(x: f32, y: f32, size: c_int, col: rl.Color, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch buf[0..0];
    buf[s.len] = 0;
    if (custom_font) {
        const px = @as(f32, @floatFromInt(size)) * 1.18;
        rl.DrawTextEx(ui_font, @ptrCast(&buf), .{ .x = @floor(x), .y = @floor(y - px * 0.08) }, px, 0.3, col);
    } else {
        rl.DrawText(@ptrCast(&buf), @intFromFloat(x), @intFromFloat(y), size, col);
    }
}

pub fn panel(x: f32, y: f32, w: f32, h: f32) void {
    const r = rect(x, y, w, h);
    if (panel_count < panels.len) {
        panels[panel_count] = r;
        panel_count += 1;
    }
    rl.DrawRectangleRounded(r, 0.04, 6, .{ .r = 18, .g = 20, .b = 30, .a = 225 });
}

/// Draws a button; returns true when it was clicked this frame.
pub fn button(r: rl.Rectangle, comptime fmt: []const u8, args: anytype) bool {
    if (panel_count < panels.len) {
        panels[panel_count] = r;
        panel_count += 1;
    }
    const hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), r);
    rl.DrawRectangleRounded(r, 0.3, 6, if (hover) rgb(60, 66, 90) else rgb(36, 40, 58));
    text(r.x + 10, r.y + 8, 14, rgb(225, 225, 235), fmt, args);
    return hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT);
}

pub fn bar(x: f32, y: f32, label: []const u8, v: f32, col: rl.Color) void {
    text(x, y, 11, rgb(160, 165, 180), "{s}", .{label});
    rl.DrawRectangleRec(rect(x + 100, y + 2, 170, 8), rgb(36, 40, 54));
    rl.DrawRectangleRec(rect(x + 100, y + 2, 170 * std.math.clamp(v, 0, 1), 8), col);
}

pub fn bar2(x: f32, y: f32, label: []const u8, a: f32, b: f32, col: rl.Color) void {
    text(x, y, 11, rgb(160, 165, 180), "{s}", .{label});
    rl.DrawRectangleRec(rect(x + 100, y + 2, 82, 8), rgb(36, 40, 54));
    rl.DrawRectangleRec(rect(x + 100, y + 2, 82 * std.math.clamp(a, 0, 1), 8), col);
    rl.DrawRectangleRec(rect(x + 188, y + 2, 82, 8), rgb(36, 40, 54));
    rl.DrawRectangleRec(rect(x + 188, y + 2, 82 * std.math.clamp(b, 0, 1), 8), col);
}

pub fn rgb(r: u8, g: u8, b: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

pub fn withAlpha(c: rl.Color, a: u8) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

pub fn rect(x: f32, y: f32, w: f32, h: f32) rl.Rectangle {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

/// HighDPI-safe BeginMode2D: raylib's BeginMode2D resets modelview without
/// re-applying screenScale on macOS Retina displays, so scale offset and zoom.
pub fn beginMode2D(cam: rl.Camera2D) void {
    const dpi = rl.GetWindowScaleDPI();
    var c = cam;
    c.offset.x *= dpi.x;
    c.offset.y *= dpi.y;
    c.zoom *= dpi.x;
    rl.BeginMode2D(c);
}

pub fn takeScreenshot(path: [:0]const u8) void {
    const img = rl.LoadImageFromScreen();
    defer rl.UnloadImage(img);
    _ = rl.ExportImage(img, path.ptr);
}

/// Random seed from raylib's time-seeded generator.
pub fn newSeed() u64 {
    const a: u64 = @intCast(rl.GetRandomValue(0, std.math.maxInt(i32)));
    const b: u64 = @intCast(rl.GetRandomValue(0, std.math.maxInt(i32)));
    return a << 32 | b;
}
