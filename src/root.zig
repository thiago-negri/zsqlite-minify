const std = @import("std");
const assert = std.debug.assert;

// Hacky, but works for me
pub fn minifySql(alloc: std.mem.Allocator, sql: [:0]const u8) ![:0]const u8 {
    const MinifySqlMode = enum { identifier, string, whitespace, line_comment, multiline_comment };

    // Store every "useful word" here, it should countain every sequence
    // of chars from the original SQL, except whitespace and comments.
    var array = std.ArrayList([]const u8).init(alloc);
    defer array.deinit();

    // Populate the array of "useful words"
    var mode: MinifySqlMode = .whitespace;
    var identifier_start_index: usize = 0;
    var current_index: usize = 0;
    var escape = false;
    var string_char: u8 = 0;
    const sql_len_with_sentintel = sql.len + 1;
    while (current_index < sql_len_with_sentintel) : (current_index += 1) {
        const char = sql[current_index];
        switch (mode) {
            .identifier => {
                switch (char) {
                    '0'...'9', 'A'...'Z', 'a'...'z', '_', ')', '(', ',', ';', '=', '@', '?', '.', '`' => {
                        // ignore
                    },
                    else => {
                        const identifier = sql[identifier_start_index..current_index];
                        try array.append(identifier);

                        // We may have hit a "-", a "/" so we need to re-evaluate it to check if we
                        // are starting a comment.  That's why we rewind the current index by one.
                        mode = .whitespace;
                        current_index -= 1;
                    },
                }
            },
            .string => {
                if (!escape) {
                    if (char == string_char) {
                        const identifier = sql[identifier_start_index .. current_index + 1];
                        try array.append(identifier);
                        mode = .whitespace;
                    } else if (char == '\\') {
                        escape = true;
                    }
                } else {
                    escape = false;
                }
            },
            .whitespace => {
                switch (char) {
                    '"', '\'' => {
                        mode = .string;
                        string_char = char;
                        identifier_start_index = current_index;
                    },
                    '-' => {
                        if (current_index + 1 < sql.len and sql[current_index + 1] == '-') {
                            mode = .line_comment;
                            current_index += 1;
                        } else {
                            mode = .identifier;
                            identifier_start_index = current_index;
                        }
                    },
                    '/' => {
                        if (current_index + 1 < sql.len and sql[current_index + 1] == '*') {
                            mode = .multiline_comment;
                        } else {
                            mode = .identifier;
                            identifier_start_index = current_index;
                        }
                    },
                    ' ', '\r', '\t', '\n' => {
                        // ignore
                    },
                    else => {
                        mode = .identifier;
                        identifier_start_index = current_index;
                    },
                }
            },
            .line_comment => {
                if (char == '\n') {
                    mode = .whitespace;
                }
            },
            .multiline_comment => {
                if (char == '*' and current_index + 1 < sql.len and sql[current_index + 1] == '/') {
                    mode = .whitespace;
                    current_index += 1;
                }
            },
        }
    }

    // Calculate the total number of bytes we will need for the minified SQL
    var total_length: usize = 0;
    var require_space_after = false;
    for (array.items) |item| {
        if (total_length > 0) {
            const first_char = item[0];
            switch (first_char) {
                // Would be awesome to extract that list into a comptime const,
                // monitor https://github.com/ziglang/zig/issues/21507
                ')', '(', ',', ';', '=', '!', '<', '>', '"', '`', '\'' => {
                    // ignore
                },
                else => {
                    if (require_space_after) {
                        total_length += 1;
                    }
                },
            }
        }

        total_length += item.len;

        const last_char = item[item.len - 1];
        switch (last_char) {
            ')', '(', ',', ';', '=', '!', '<', '>', '"', '`', '\'' => {
                require_space_after = false;
            },
            else => {
                require_space_after = true;
            },
        }
    }
    const last_item = array.items[array.items.len - 1];
    if (last_item[last_item.len - 1] == ';') {
        total_length -= 1;
    }

    // Copy each identifier slice into a new minified SQL resulting string
    var minified_sql: [:0]u8 = try alloc.allocWithOptions(u8, total_length, null, 0);
    current_index = 0;
    for (array.items) |item| {
        // std.debug.print("{s}\n", .{item});
        if (current_index > 0) {
            const first_char = item[0];
            switch (first_char) {
                ')', '(', ',', ';', '=', '!', '<', '>', '"', '`', '\'' => {
                    // ignore
                },
                else => {
                    if (require_space_after) {
                        minified_sql[current_index] = ' ';
                        current_index += 1;
                    }
                },
            }
        }

        for (minified_sql[current_index .. current_index + item.len], item) |*d, s| d.* = s;
        current_index += item.len;

        const last_char = item[item.len - 1];
        switch (last_char) {
            ')', '(', ',', ';', '=', '!', '<', '>', '"', '`', '\'' => {
                require_space_after = false;
            },
            else => {
                require_space_after = true;
            },
        }
    }
    // Make sure we end with the sentinel (this will also overwrite the last ';' if present)
    // Leaving a ';' at the end will make the migration try to apply an empty SQL after, which causes a MISUSE error
    // on SQLite
    minified_sql[total_length] = 0;

    // std.debug.print("{s}\n", .{minified_sql});

    return minified_sql;
}

test "minified sqls at run time" {
    const alloc = std.testing.allocator;

    {
        const sql =
            \\-- My awesome table!
            \\CREATE TABLE awe (
            \\    id INT PRIMARY KEY , -- This is the primary key
            \\    age INT ( 10 /* Why 10? 
            \\                          because I can! */
            \\) NOT NULL
            \\);
            \\
            \\    /* MORE */
            \\ UPDATE awe   SET age = 33 WHERE id <> 1 ;
        ;
        const expect = "CREATE TABLE awe(id INT PRIMARY KEY,age INT(10)NOT NULL);UPDATE awe SET age=33 WHERE id<>1";

        const actual = try minifySql(alloc, sql);
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(expect, actual);
    }

    {
        const sql =
            \\SELECT foo, bar
            \\ FROM spam
            \\ WHERE eggs > ?
            \\   AND eggs < ?;
        ;
        const expect = "SELECT foo,bar FROM spam WHERE eggs>? AND eggs<?";

        const actual = try minifySql(alloc, sql);
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(expect, actual);
    }

    {
        const sql =
            \\INSERT INTO spam ( foo, bar )
            \\ VALUES          (   ?,   ? );
        ;
        const expect = "INSERT INTO spam(foo,bar)VALUES(?,?)";

        const actual = try minifySql(alloc, sql);
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(expect, actual);
    }

    {
        const sql =
            \\SELECT foo
            \\  FROM bar
            \\ WHERE EXISTS (
            \\       SELECT 1
            \\          FROM zoo
            \\          WHERE zoo.id = bar.id
            \\                AND zoo.type = ?
            \\ );
        ;
        const expect = "SELECT foo FROM bar WHERE EXISTS(SELECT 1 FROM zoo WHERE zoo.id=bar.id AND zoo.type=?)";

        const actual = try minifySql(alloc, sql);
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(expect, actual);
    }

    {
        const sql =
            \\SELECT `foo`
            \\  FROM "bar"
            \\ WHERE EXISTS (
            \\       SELECT 1
            \\          FROM "zoo"
            \\          WHERE `zoo`."id" = "bar".`id`
            \\                AND zoo."type" = ?
            \\ );
        ;
        const expect = "SELECT`foo`FROM\"bar\"WHERE EXISTS(SELECT 1 FROM\"zoo\"WHERE`zoo`.\"id\"=\"bar\".`id`AND zoo.\"type\"=?)";

        const actual = try minifySql(alloc, sql);
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(expect, actual);
    }
}

test "minified sqls at build time" {
    const sqls = @import("minified-sqls").minified_sqls;
    try std.testing.expectEqualStrings("SELECT foo,bar FROM spam WHERE eggs>? AND eggs<?", sqls[0]);
    try std.testing.expectEqualStrings("INSERT INTO spam(foo,bar)VALUES(?,?)", sqls[1]);
}

pub const MinifiedSqlPath = struct { files: std.ArrayList([]const u8), sqls: std.ArrayList([:0]const u8) };

/// Minify all SQL files in a directory (and sub directories)
pub fn minifySqlPath(path: []const u8, alloc: std.mem.Allocator) !MinifiedSqlPath {
    const DirInfo = struct { name: ?[]const u8, dir: std.fs.Dir };
    var dir_info_array = std.ArrayList(DirInfo).init(alloc);
    defer {
        for (dir_info_array.items) |*dir_info| {
            if (dir_info.name) |name| alloc.free(name);
            dir_info.dir.close();
        }
        dir_info_array.deinit();
    }

    var files = std.ArrayList([]const u8).init(alloc);
    errdefer {
        for (files.items) |item| {
            alloc.free(item);
        }
        files.deinit();
    }

    var sqls = std.ArrayList([:0]const u8).init(alloc);
    errdefer {
        for (sqls.items) |item| {
            alloc.free(item);
        }
        sqls.deinit();
    }

    var start_dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    {
        errdefer start_dir.close();
        try dir_info_array.append(DirInfo{ .name = null, .dir = start_dir });
    }

    while (dir_info_array.popOrNull()) |dir_info| {
        var dir = dir_info.dir;
        defer if (dir_info.name) |name| alloc.free(name);
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |file| {
            if (file.kind == .directory) {
                var sub_dir = try dir.openDir(file.name, .{ .iterate = true });
                {
                    errdefer sub_dir.close();

                    const name = blk: {
                        if (dir_info.name) |name| {
                            const new_name = try alloc.alloc(u8, name.len + file.name.len + 1);
                            errdefer alloc.free(new_name);
                            std.mem.copyForwards(u8, new_name, name);
                            new_name[name.len] = '/';
                            std.mem.copyForwards(u8, new_name[name.len + 1 ..], file.name);
                            break :blk new_name;
                        }
                        break :blk try alloc.dupe(u8, file.name);
                    };
                    errdefer alloc.free(name);

                    try dir_info_array.append(DirInfo{ .name = name, .dir = sub_dir });
                }
            }
            if (file.kind != .file) {
                continue;
            }
            const extension = ".sql";
            if (file.name.len < extension.len + 1) {
                continue;
            }
            if (!std.mem.eql(u8, file.name[file.name.len - extension.len ..], extension)) {
                continue;
            }
            const stat = try dir.statFile(file.name);
            const size = stat.size + 1; // +1 for sentinel
            const sql = try dir.readFileAllocOptions(alloc, file.name, size, size, @alignOf(u8), 0);
            const minified_sql = minified_sql: {
                defer alloc.free(sql);
                break :minified_sql try minifySql(alloc, sql);
            };
            {
                errdefer alloc.free(minified_sql);

                const name = blk: {
                    if (dir_info.name) |name| {
                        const new_name = try alloc.alloc(u8, name.len + file.name.len + 1);
                        errdefer alloc.free(new_name);
                        std.mem.copyForwards(u8, new_name, name);
                        new_name[name.len] = '/';
                        std.mem.copyForwards(u8, new_name[name.len + 1 ..], file.name);
                        break :blk new_name;
                    }
                    break :blk try alloc.dupe(u8, file.name);
                };
                errdefer alloc.free(name);

                try files.append(name);
                try sqls.append(minified_sql);
            }
        }
    }

    const result: MinifiedSqlPath = .{ .files = files, .sqls = sqls };
    return result;
}

/// Embed a minified SQL at comptime
pub fn embedMinifiedSql(comptime filename: []const u8) [:0]const u8 {
    const minified_sqls = @import("minified-sqls-path");

    const filename_index = f: inline for (minified_sqls.filenames, 0..) |e, index| {
        if (comptime std.mem.eql(u8, filename, e)) {
            break :f index;
        }
    } else @compileError("filename not available " ++ filename ++ ", available files " ++
        std.fmt.comptimePrint("{s}", .{minified_sqls.filenames}));

    const sql = comptime minified_sqls.sqls[filename_index];
    return sql;
}

test "embedded files loaded through path" {
    const foo_create = embedMinifiedSql("sqls/foo/create.sql");
    try std.testing.expectEqualStrings("CREATE TABLE foo(id INT PRIMARY KEY,name TEXT)", foo_create);

    const foo_select = embedMinifiedSql("sqls/foo/select.sql");
    try std.testing.expectEqualStrings("SELECT id,name FROM foo", foo_select);

    const bar_other = embedMinifiedSql("sqls/bar/other.sql");
    try std.testing.expectEqualStrings("DELETE FROM bar", bar_other);
}
