//! Application runtime implementation that uses libwayland-client.
//!
//! This works on Linux with OpenGL.

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");
const Config = @import("../config.zig").Config;

const log = std.log.scoped(.wayland);

const RoundtripContext = struct {
    shm: ?*wl.Shm = null,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
};

pub const App = struct {
    app: *CoreApp,
    config: Config,

    display: *wl.Display,
    registry: *wl.Registry,
    shm: *wl.Shm,
    compositor: *wl.Compositor,
    wm_base: *xdg.WmBase,

    pub const Options = struct {};

    pub fn init(core_app: *CoreApp, _: Options) !App {
        const display = try wl.Display.connect(null);
        const registry = try display.getRegistry();

        var roundtrip_context = RoundtripContext{};

        registry.setListener(*RoundtripContext, registryListener, &roundtrip_context);
        if (display.roundtrip() != .SUCCESS) {
            log.warn("Display roundtrip failed, exiting", .{});
            std.posix.exit(1);
        }

        const shm = roundtrip_context.shm orelse {
            log.warn("No wl_shm global, exiting", .{});
            std.posix.exit(1);
        };
        const compositor = roundtrip_context.compositor orelse {
            log.warn("No wl_compositor global, exiting", .{});
            std.posix.exit(1);
        };
        const wm_base = roundtrip_context.wm_base orelse {
            log.warn("No xdg_wm_base global, exiting", .{});
            std.posix.exit(1);
        };

        // Load our configuration
        var config = try Config.load(core_app.alloc);
        errdefer config.deinit();

        // If we had configuration errors, then log them.
        // TODO(theonlymrcat): Display these to the user graphically
        if (!config._diagnostics.empty()) {
            var buf = std.ArrayList(u8).init(core_app.alloc);
            defer buf.deinit();
            for (config._diagnostics.items()) |diag| {
                try diag.write(buf.writer());
                log.warn("configuration error: {s}", .{buf.items});
                buf.clearRetainingCapacity();
            }

            // If we have any CLI errors, exit.
            if (config._diagnostics.containsLocation(.cli)) {
                log.warn("CLI errors detected, exiting", .{});
                std.posix.exit(1);
            }
        }

        // Queue a single new window that starts on launch
        _ = core_app.mailbox.push(.{
            .new_window = .{},
        }, .{ .forever = {} });

        return .{
            .app = core_app,
            .config = config,

            .display = display,
            .registry = registry,
            .shm = shm,
            .compositor = compositor,
            .wm_base = wm_base,
        };
    }

    pub fn terminate(self: *App) void {
        self.config.deinit();
    }

    /// Run the event loop. This doesn't return until the app exits.
    pub fn run(self: *App) !void {
        while (true) {
            if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;

            // Tick the terminal app
            const should_quit = try self.app.tick(self);
            if (should_quit or self.app.surfaces.items.len == 0) {
                for (self.app.surfaces.items) |surface| {
                    surface.close(false);
                }

                return;
            }
        }
    }

    /// Wakeup the event loop. This should be able to be called from any thread.
    pub fn wakeup(self: *const App) void {
        _ = self;
        // TODO(theonlymrcat): Uhhhh....
    }

    /// Perform a given action.
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !void {
        switch (action) {
            .new_window => _ = try self.newSurface(switch (target) {
                .app => null,
                .surface => |v| v,
            }),

            .reload_config => try self.reloadConfig(target, value),

            // Unimplemented
            // TODO(theonlymrcat): Implement all of these; show graphical response for invalid actions
            .new_tab,
            .new_split,
            .close_all_windows,
            .toggle_fullscreen,
            .toggle_tab_overview,
            .toggle_window_decorations,
            .toggle_quick_terminal,
            .toggle_visibility,
            .move_tab,
            .goto_tab,
            .goto_split,
            .resize_split,
            .equalize_splits,
            .toggle_split_zoom,
            .present_terminal,
            .size_limit,
            .initial_size,
            .cell_size,
            .inspector,
            .render_inspector,
            .desktop_notification,
            .set_title,
            .pwd,
            .mouse_shape,
            .mouse_visibility,
            .mouse_over_link,
            .renderer_health,
            .open_config,
            .quit_timer,
            .secure_input,
            .key_sequence,
            .color_change,
            .config_change,
            => log.info("unimplemented action={}", .{action}),
        }
    }

    pub fn redrawSurface(self: *App, surface: *Surface) void {
        _ = self;
        _ = surface;

        // TODO(theonlymrcat): This doesn't get called for GLFW, but should it be called here?
    }

    pub fn redrawInspector(self: *App, surface: *Surface) void {
        _ = self;
        _ = surface;

        // TODO(theonlymrcat): The inspector
    }

    fn newSurface(self: *App, parent_: ?*CoreSurface) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try self.app.alloc.create(Surface);
        errdefer self.app.alloc.destroy(surface);

        // Create the surface -- because windows are surfaces.
        try surface.init(self);
        errdefer surface.deinit();

        // TODO(theonlymrcat): Inherit some properties from the parent
        _ = parent_;

        return surface;
    }

    fn reloadConfig(
        self: *App,
        target: apprt.action.Target,
        opts: apprt.action.ReloadConfig,
    ) !void {
        if (opts.soft) {
            switch (target) {
                .app => try self.app.updateConfig(self, &self.config),
                .surface => |core_surface| try core_surface.updateConfig(
                    &self.config,
                ),
            }
            return;
        }

        // Load our configuration
        var config = try Config.load(self.app.alloc);
        errdefer config.deinit();

        // Call into our app to update
        switch (target) {
            .app => try self.app.updateConfig(self, &config),
            .surface => |core_surface| try core_surface.updateConfig(&config),
        }

        // Update the existing config, be sure to clean up the old one.
        self.config.deinit();
        self.config = config;
    }
};

pub const Surface = struct {
    // The app we're a part of
    app: *App,

    /// A core surface
    core_surface: CoreSurface,

    pool: *wl.ShmPool,
    buffer: *wl.Buffer,
    wl_surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    xdg_toplevel: *xdg.Toplevel,

    should_close: bool,

    pub fn init(self: *Surface, app: *App) !void {
        self.app = app;
        self.should_close = false;
        errdefer self.* = undefined;

        self.buffer = blk: {
            const width = 128;
            const height = 128;
            const stride = width * 4;
            const size = stride * height;

            const fd = try posix.memfd_create("ghostty", 0);
            try posix.ftruncate(fd, size);
            const data = try posix.mmap(
                null,
                size,
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                fd,
                0,
            );
            @memset(data, 0xff);

            self.pool = try app.shm.createPool(fd, size);
            errdefer self.pool.destroy();

            break :blk try self.pool.createBuffer(0, width, height, stride, wl.Shm.Format.argb8888);
        };
        errdefer self.buffer.destroy();

        self.wl_surface = try app.compositor.createSurface();
        errdefer self.wl_surface.destroy();
        self.xdg_surface = try app.wm_base.getXdgSurface(self.wl_surface);
        errdefer self.xdg_surface.destroy();
        self.xdg_toplevel = try self.xdg_surface.getToplevel();
        errdefer self.xdg_toplevel.destroy();

        self.xdg_surface.setListener(*wl.Surface, xdgSurfaceListener, self.wl_surface);
        self.xdg_toplevel.setListener(*Surface, xdgToplevelListener, self);

        self.wl_surface.commit();
        if (app.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        self.wl_surface.attach(self.buffer, 0, 0);
        self.wl_surface.commit();

        // Add ourselves to the list of surfaces on the app.
        try app.app.addSurface(self);
        errdefer app.app.deleteSurface(self);

        // Get our new surface config
        var config = try apprt.surface.newConfig(app.app, &app.config);
        defer config.deinit();

        // Initialize our surface now that we have the stable pointer.
        // try self.core_surface.init(
        //     app.app.alloc,
        //     &config,
        //     app.app,
        //     app,
        //     self,
        // );
        // errdefer self.core_surface.deinit();
    }

    pub fn deinit(self: *Surface) void {
        // Remove ourselves from the list of known surfaces in the app.
        self.app.app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        // self.core_surface.deinit();

        self.xdg_toplevel.destroy();
        self.xdg_surface.destroy();
        self.wl_surface.destroy();
        self.buffer.destroy();
        self.pool.destroy();
    }

    pub fn close(self: *Surface, processActive: bool) void {
        _ = processActive; // TODO(theonlymrcat): Prompt user
        self.deinit();
        self.app.app.alloc.destroy(self);
    }

    pub fn getTitle(_: *Surface) ?[:0]const u8 {
        // TODO(theonlymrcat): Track window title
        return null;
    }

    pub fn getSize(_: *Surface) !apprt.SurfaceSize {
        // TODO(theonlymrcat): Support resizing
        return apprt.SurfaceSize{ .width = 128, .height = 128 };
    }

    pub fn getContentScale(_: *Surface) !apprt.ContentScale {
        // TODO(theonlymrcat): Get this from wp_fractional_scale_manager
        return apprt.ContentScale{ .x = 1, .y = 1 };
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !void {
        // TODO(theonlymrcat)
        _ = self;
        _ = clipboard_type;
        _ = state;
    }

    pub fn setClipboardString(
        self: *const Surface,
        val: [:0]const u8,
        clipboard_type: apprt.Clipboard,
        confirm: bool,
    ) !void {
        // TODO(theonlymrcat)
        _ = self;
        _ = val;
        _ = clipboard_type;
        _ = confirm;
    }

    pub fn shouldClose(self: *Surface) bool {
        return self.should_close;
    }
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *RoundtripContext) void {
    switch (event) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                context.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, surface: *wl.Surface) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            surface.commit();
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, surface: *Surface) void {
    switch (event) {
        .configure => {},
        .close => surface.should_close = true,
    }
}
