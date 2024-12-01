# zsqlite-minify

Minify SQL scripts.

*Note:* This is a quick hack to minify some SQLs I use at a personal project.  It doesn't cover the entire SQL.


## Install

Add as a dependency:

```sh
zig fetch --save "https://github.com/thiago-negri/zsqlite-minify/archive/refs/heads/master.zip"
```

Add to your build:

```zig
// Add SQL Minify
const zsqlite_minify = b.dependency("zsqlite-minify", .{
    .target = target,
    .optimize = optimize,
});
const zsqlite_minify_module = zsqlite_minify.module("zsqlite-minify");
exe.root_module.addImport("zsqlite-minify", zsqlite_minify_module);
```


## Use

```zig
const minifySql = @import("zsqlite-minify").minifySql;

const sql = "SELECT a, b FROM foo;";
const alloc = ...; // how the resulting SQL will be allocated
const minified_sql = try minifySql(alloc, sql);
defer alloc.free(minified_sql);
```


## Comptime

Hopefully this can be done at comptime at some point.  Right now it's impossible because it uses an allocator.
Check [zig#1291](https://github.com/ziglang/zig/issues/1291).

What is possible is to use it during build and provide the minified SQLs as a module:

```zig
const minifySql = @import("zsqlite-minify").minifySql;

pub fn build(b: *std.Build) !void {
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

    your_exe.root_module.addImport("minified-sqls", options.createModule());
}
```

Then it's possible to import and use the minified SQLs:

```zig
const sqls = @import("minified-sqls").minified_sqls;

std.debug.print("Minified SQLs:\n", .{});
for (sqls) |sql| {
    std.debug.print("{s}\n", .{sql});
}
```

This is done by [zsqlite-migrate](https://github.com/thiago-negri/zsqlite-migrate) to embed minified SQL migrations.

Also done as part of the tests in this project.