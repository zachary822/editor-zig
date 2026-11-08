const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.dependency("translate_c", .{});
    const t: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{
            .{ .name = "ncurses" },
        },
    });

    // Lua: compile the C sources from the tarball into a static library.
    const lua_dep = b.dependency("lua", .{});
    const lua = b.addLibrary(.{
        .name = "lua",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lua.root_module.addCSourceFiles(.{
        .root = lua_dep.path("src"),
        .files = &.{
            "lapi.c",     "lcode.c",    "lctype.c",   "ldebug.c",  "ldo.c",
            "ldump.c",    "lfunc.c",    "lgc.c",      "llex.c",    "lmem.c",
            "lobject.c",  "lopcodes.c", "lparser.c",  "lstate.c",  "lstring.c",
            "ltable.c",   "ltm.c",      "lundump.c",  "lvm.c",     "lzio.c",
            "lauxlib.c",  "lbaselib.c", "lcorolib.c", "ldblib.c",  "liolib.c",
            "lmathlib.c", "loadlib.c",  "loslib.c",   "lstrlib.c", "ltablib.c",
            "lutf8lib.c", "linit.c",
        },
        .flags = &.{ "-std=gnu99", "-DLUA_USE_POSIX" },
    });
    t.addIncludePath(lua_dep.path("src")); // translate-c finds lua.h here
    t.linkLibrary(lua); // links liblua.a into users of `c`

    const mod = b.addModule("editor_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const rope_dep = b.dependency("rope_zig", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "editor_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "editor_zig", .module = mod },
                .{ .name = "c", .module = t.mod },
                .{ .name = "rope", .module = rope_dep.module("rope_zig") },
            },
        }),
    });
    b.installArtifact(exe);

    // `zig build run -- <args>`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
