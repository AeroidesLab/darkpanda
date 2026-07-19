// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("darkpanda");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = lp.log;
const App = lp.App;
const Config = lp.Config;
const SigHandler = @import("Sighandler.zig");
pub const panic = lp.crash_handler.panic;

pub const std_options: std.Options = .{
    // std.crypto.random's default backend mmaps a thread-local 528-byte state
    // page on first use and never unmaps it. One detached thread is created per
    // CDP connection, so route random calls to the operating-system source.
    .crypto_always_getrandom = true,
};

pub fn main() !void {
    var gpa_instance: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    const gpa = if (builtin.mode == .Debug) gpa_instance.allocator() else std.heap.c_allocator;

    defer if (builtin.mode == .Debug) {
        if (gpa_instance.detectLeaks()) std.posix.exit(1);
    };

    var main_arena_instance = std.heap.ArenaAllocator.init(gpa);
    const main_arena = main_arena_instance.allocator();
    defer main_arena_instance.deinit();

    run(gpa, main_arena) catch |err| {
        log.fatal(.app, "exit", .{ .err = err });
        std.posix.exit(1);
    };
}

fn run(allocator: Allocator, main_arena: Allocator) !void {
    lp.core_dump.disableIfRequested();

    const args = try Config.parseArgs(main_arena);
    defer args.deinit(main_arena);

    switch (args.mode) {
        .help => |tag| return args.printUsageAndExit(tag, true),
        .version => {
            var stdout = std.fs.File.stdout().writer(&.{});
            try stdout.interface.print("{s}\n", .{lp.build_config.version});
            return std.process.cleanExit();
        },
        .serve => {},
    }

    if (args.logLevel()) |level| log.opts.level = level;
    if (args.logFormat()) |format| log.opts.format = format;
    log.opts.scope_enabled = log.resolveFilterScopes(args.logFilterScopes().items);

    const sighandler = try main_arena.create(SigHandler);
    sighandler.* = .{ .arena = main_arena };
    try sighandler.install();

    var app = try App.init(allocator, &args);
    defer app.deinit();

    try sighandler.on(lp.Network.stop, .{&app.network});
    const opts = args.mode.serve;
    log.debug(.app, "startup", .{ .mode = "serve", .snapshot = app.snapshot.fromEmbedded() });
    const address = std.net.Address.parseIp(opts.host, opts.port) catch |err| {
        log.fatal(.app, "invalid server address", .{ .err = err, .host = opts.host, .port = opts.port });
        return args.printUsageAndExit(.serve, false);
    };

    var server = lp.Server.init(app, address) catch |err| {
        if (err == error.AddressInUse) {
            log.fatal(.app, "address already in use", .{
                .host = opts.host,
                .port = opts.port,
                .hint = "Another process is already listening on this address. Stop it or choose another port.",
            });
        } else {
            log.fatal(.app, "server run error", .{ .err = err });
        }
        return err;
    };
    defer server.deinit();

    try sighandler.on(lp.Server.shutdown, .{server});
    app.network.run();
}
