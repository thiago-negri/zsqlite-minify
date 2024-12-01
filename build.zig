const std = @import("std");

// Export it so other projects can minify SQL as part of their builds
pub const minifySql = @import("./src/root.zig").minifySql;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("zsqlite-minify", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const mod_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_mod_unit_tests = b.addRunArtifact(mod_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_unit_tests.step);

    // zig fmt: off
    const sqls: []const [:0]const u8 = &[_][:0]const u8{
        \\SELECT foo, bar
        \\ FROM spam
        \\ WHERE eggs > ?
        \\   AND eggs < ?;
        ,
        \\INSERT INTO spam ( foo, bar )
        \\ VALUES          (   ?,   ? );
    };
    // zig fmt: on
    const sqls_len = comptime sqls.len;
    var minified_sqls: [sqls_len][:0]const u8 = undefined;
    for (sqls, 0..) |sql, index| {
        minified_sqls[index] = try minifySql(b.allocator, sql);
    }

    const options = b.addOptions();
    options.addOption([]const [:0]const u8, "minified_sqls", &minified_sqls);

    mod_unit_tests.root_module.addImport("minified-sqls", options.createModule());
}
