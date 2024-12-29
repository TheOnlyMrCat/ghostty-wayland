//! Application runtime implementation that uses libwayland-client.
//!
//! This works on Linux with OpenGL.

const wayland = @import("wayland");
const CoreApp = @import("../App.zig");
const Config = @import("../config.zig").Config;

pub const App = struct {
    app: *CoreApp,
    config: Config,

    pub const Options = struct {};

    pub fn init(core_app: *CoreApp, _: Options) !App {
        // Load our configuration
        var config = try Config.load(core_app.alloc);
        errdefer config.deinit();

        return .{
            .app = core_app,
            .config = config,
        };
    }

    pub fn terminate(self: *App) void {
        self.config.deinit();
    }

    /// Run the event loop. This doesn't return until the app exits.
    pub fn run(_: *App) !void {}
};

pub const Surface = struct {
    pub fn deinit(_: *Surface) void {}
};
