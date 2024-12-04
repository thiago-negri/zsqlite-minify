const std = @import("std");
const assert = std.debug.assert;

// Export it on build so other projects can minify SQL as part of their builds
const lib = @import("./src/root.zig");
pub const minifySql = lib.minifySql;
pub const minifySqlPath = lib.minifySqlPath;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = .{
        .minify_root_path = b.option([]const u8, "minify_root_path", "The root path where all the SQL files are"),
        .minify_files_prefix = b.option(
            []const u8,
            "minify_files_prefix",
            "A prefix to add to all your SQL files references, useful to 'gf' the file in VIM",
        ) orelse "",
    };

    const zsqlite_minify_mod = b.addModule("zsqlite-minify", .{
        .root_source_file = b.path("src/root.zig"),
    });
    if (build_options.minify_root_path) |path| {
        const sqls_path = try minifySqlPath(path, build_options.minify_files_prefix, b.allocator);
        const mod_options = b.addOptions();
        mod_options.addOption([]const []const u8, "filenames", sqls_path.files.items);
        mod_options.addOption([]const [:0]const u8, "sqls", sqls_path.sqls.items);
        zsqlite_minify_mod.addOptions("minified-sqls-path", mod_options);
    }

    const mod_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_mod_unit_tests = b.addRunArtifact(mod_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_unit_tests.step);

    const sqls: []const [:0]const u8 = &[_][:0]const u8{
        \\SELECT foo, bar
        \\ FROM spam
        \\ WHERE eggs > ?
        \\   AND eggs < ?;
        ,
        \\INSERT INTO spam ( foo, bar )
        \\ VALUES          (   ?,   ? );
    };
    const sqls_len = comptime sqls.len;
    var minified_sqls: [sqls_len][:0]const u8 = undefined;
    for (sqls, 0..) |sql, index| {
        minified_sqls[index] = try minifySql(b.allocator, sql);
    }

    const minified_sqls_test = b.addOptions();
    minified_sqls_test.addOption([]const [:0]const u8, "minified_sqls", &minified_sqls);
    mod_unit_tests.root_module.addImport("minified-sqls", minified_sqls_test.createModule());

    const sqls_path = try minifySqlPath("./src/", "", b.allocator);
    const minified_sqls_path_test = b.addOptions();
    minified_sqls_path_test.addOption([]const []const u8, "filenames", sqls_path.files.items);
    minified_sqls_path_test.addOption([]const [:0]const u8, "sqls", sqls_path.sqls.items);
    mod_unit_tests.root_module.addImport("minified-sqls-path", minified_sqls_path_test.createModule());
}
