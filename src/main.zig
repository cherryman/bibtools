const std = @import("std");
const assert = std.debug.assert;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

pub fn main() !void {
    const stdin = std.io.getStdIn().reader();
    var stdout = std.io.getStdOut().writer();
    var reader = Reader(1024, @TypeOf(stdin)).init(stdin);
    var entries = try reader.parse_all(std.heap.page_allocator);

    for (entries.items) |*entry| {
        try entry.pretty_print(stdout);
        try stdout.writeAll("\n");
        entry.deinit();
    }

    entries.deinit();
}

/// Modelled after [`std.json.Scanner`] as it's idiomatic and is
/// approximately what I was going for. Here I cut and inlined some
/// stuff out since the syntax is somewhat simpler.
const Scanner = struct {
    const Self = @This();

    input: []const u8 = "",
    cursor: usize = 0,
    state: State = .none,

    // symbols: std.StringHashMap([]const u8),
    brace_depth: usize = 0,
    in_comment: bool = false,
    is_end_of_input: bool = false,

    // TODO: taken from `Diagnostics`, need to use
    line_number: usize = 1,
    // line_start_cursor: usize = @as(usize, @bitCast(@as(isize, -1))),
    line_start_cursor: usize = 0,
    // total_bytes_before_current_input: usize = 0,
    // cursor_pointer: *const usize = undefined,

    // TODO: cite https://github.com/aclements/biblib
    //
    // other links:
    // https://www.bibtex.org/Format/
    // https://www.bibtex.org/SpecialSymbols/
    // https://www.bibtex.com/g/bibtex-format/
    // https://tug.ctan.org/info/bibtex/tamethebeast/ttb_en.pdf

    fn init() Self {
        return Self{};
    }

    fn deinit(self: *Self) void {
        self.* = undefined;
    }

    const State = enum {
        none,
        saw_at,
        entry_type,
        entry_post_type,
        // TODO no fuckin idea how comment works
        // comment,
        // string_set,
        // entry_members,
        pre_tag,
        tag,
        post_tag,
        pre_value,
        value_quoted,
        value_braced,
        post_value,
    };

    const Error = error{ SyntaxError, UnexpectedEndOfInput };
    const NextError = Error || error{BufferUnderrun};

    const Token = union(enum) {
        entry_begin,
        type_begin,
        type_partial: []const u8,
        type_end,
        tag_begin,
        tag_partial: []const u8,
        tag_end_no_value,
        tag_and_entry_end,
        tag_end,
        value_begin,
        value_partial: []const u8,
        value_end,
        value_and_entry_end,
        entry_end,
        end_document,
    };

    /// Feeds the scanner with more input.
    ///
    /// Should only be called after `init` or when `next` returns
    /// `error.BufferUnderrun`. Should _not_ be called after `finish`.
    pub fn feed(self: *Self, input: []const u8) void {
        assert(!self.is_end_of_input);
        self.input = input;
    }

    /// Tells the scanner that no more input will be fed.
    ///
    /// Should be called exactly once. Can be called exactly after
    /// [`feed`] or after [`next`] has returned `error.BufferUnderrun`,
    /// as long as no more input is fed.
    pub fn end_input(self: *Self) void {
        assert(!self.is_end_of_input);
        self.is_end_of_input = true;
    }

    // TODO: utf8 validation
    // TODO: utf8 bom
    // TODO: all possible chars in idents
    // TODO: duplicate tags
    // TODO: lowercase tags
    // TODO: early input handling
    // TODO: max lengths for idents
    // TODO: parentheses
    // TODO: trim values?
    // TODO: add line breaks to values?

    pub fn next(self: *Self) NextError!Token {
        while (true) {
            switch (self.state) {
                .none => {
                    switch (try self.skip_to_maybe_byte() orelse return .end_document) {
                        '@' => {
                            self.cursor += 1;
                            self.state = .saw_at;
                            return .entry_begin;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .saw_at => {
                    if (try self.skip_to_byte() == '{') {
                        return error.SyntaxError;
                    }
                    self.state = .entry_type;
                    return .type_begin;
                },

                // TODO: will need to handle comment or string set.
                // one approach: have a static array that can store
                // max(len("comment"), len("string")), dispatch on that,
                // don't return partial until we're sure it's neither.
                //
                // will need to move `.type_begin` further down.

                .entry_type => {
                    const i = self.cursor;
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            '0'...'9', 'a'...'z', 'A'...'Z', '_', '-', ':' => {
                                continue;
                            },
                            '{', ' ', '\n', '\t', '\r', '%' => {
                                self.state = .entry_post_type;
                                break;
                            },
                            else => return error.SyntaxError,
                        }
                    }
                    if (i == self.cursor) {
                        return error.BufferUnderrun;
                    }
                    return Token{ .type_partial = self.input[i..self.cursor] };
                },

                .entry_post_type => {
                    switch (try self.skip_to_byte()) {
                        '{' => {
                            self.cursor += 1;
                            self.state = .pre_tag;
                            return .type_end;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .pre_tag => {
                    switch (try self.skip_to_byte()) {
                        '}' => {
                            self.cursor += 1;
                            self.state = .none;
                            return .entry_end;
                        },
                        '0'...'9', 'a'...'z', 'A'...'Z', '_' => {
                            self.state = .tag;
                            return .tag_begin;
                        },
                        else => {
                            return error.SyntaxError;
                        },
                    }
                },

                .tag => {
                    // case should only be hit if we're at the start of a tag.
                    const i = self.cursor;
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            '0'...'9', 'a'...'z', 'A'...'Z', '_' => {
                                continue;
                            },
                            else => {
                                self.state = .post_tag;
                                break;
                            },
                        }
                    }
                    if (i == self.cursor) {
                        return error.BufferUnderrun;
                    }
                    return Token{ .tag_partial = self.input[i..self.cursor] };
                },

                .post_tag => {
                    switch (try self.skip_to_byte()) {
                        ',' => {
                            self.cursor += 1;
                            self.state = .pre_tag;
                            return .tag_end_no_value;
                        },
                        '}' => {
                            self.cursor += 1;
                            self.state = .none;
                            return .tag_and_entry_end;
                        },
                        '=' => {
                            self.cursor += 1;
                            self.state = .pre_value;
                            return .tag_end;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .pre_value => {
                    switch (try self.skip_to_byte()) {
                        '"' => {
                            self.cursor += 1;
                            self.state = .value_quoted;
                            return .value_begin;
                        },
                        '{' => {
                            self.cursor += 1;
                            self.state = .value_braced;
                            return .value_begin;
                        },
                        else => {
                            // TODO: handle variables
                            return error.SyntaxError;
                        },
                    }
                },

                // TODO: handle sub-braces. will need to track depth.
                // TODO: checking if characters are valid?
                // TODO: is there \" escaping involved?

                .value_quoted => {
                    const i = self.cursor;
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            '"' => {
                                self.state = .post_value;
                                break;
                            },
                            '{' => {
                                self.brace_depth += 1;
                                continue;
                            },
                            '}' => {
                                if (self.brace_depth == 0) {
                                    return error.SyntaxError;
                                }
                                self.brace_depth -= 1;
                                continue;
                            },
                            else => continue,
                        }
                    }
                    if (i == self.cursor) {
                        return error.BufferUnderrun;
                    }
                    const j = self.cursor;
                    self.cursor += 1;
                    return Token{ .value_partial = self.input[i..j] };
                },

                .value_braced => {
                    const i = self.cursor;
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            '}' => {
                                if (self.brace_depth == 0) {
                                    self.state = .post_value;
                                    break;
                                } else {
                                    self.brace_depth -= 1;
                                    continue;
                                }
                            },
                            '{' => {
                                self.brace_depth += 1;
                                continue;
                            },
                            else => continue,
                        }
                    }
                    if (i == self.cursor) {
                        return error.BufferUnderrun;
                    }
                    // skip closing brace
                    const j = self.cursor;
                    self.cursor += 1;
                    return Token{ .value_partial = self.input[i..j] };
                },

                .post_value => {
                    if (self.brace_depth != 0) {
                        return error.SyntaxError;
                    }

                    switch (try self.skip_to_byte()) {
                        ',' => {
                            self.cursor += 1;
                            self.state = .pre_tag;
                            return .value_end;
                        },
                        '}' => {
                            self.cursor += 1;
                            self.state = .none;
                            return .value_and_entry_end;
                        },
                        else => return error.SyntaxError,
                    }
                },
            }
        }
    }

    /// Skips whitespaces and comments until the next byte to parse.
    /// If `is_end_of_input` is true, returns `error.UnexpectedEndOfInput`.
    fn skip_to_byte(self: *Self) NextError!u8 {
        return try self.skip_to_maybe_byte() orelse return error.UnexpectedEndOfInput;
    }

    /// Skips whitespaces and comments, returning `null` if `is_end_of_input`.
    fn skip_to_maybe_byte(self: *Self) !?u8 {
        self.skip_whitespace();
        if (self.cursor < self.input.len) {
            return self.input[self.cursor];
        }
        if (self.is_end_of_input) {
            return null;
        }
        return error.BufferUnderrun;
    }

    /// Skips whitespaces and comments.
    fn skip_whitespace(self: *Self) void {
        while (self.cursor < self.input.len) : (self.cursor += 1) {
            if (self.in_comment) {
                self.skip_comment();
                continue;
            }
            switch (self.input[self.cursor]) {
                '\n' => {
                    self.line_number += 1;
                    self.line_start_cursor = self.cursor;
                    continue;
                },
                ' ', '\t', '\r' => continue,
                '%' => {
                    self.in_comment = true;
                    continue;
                },
                else => return,
            }
        }
    }

    /// If `in_comment` is true, skips until the end of the line.
    /// Panics if `in_comment` is false.
    fn skip_comment(self: *Self) void {
        assert(self.in_comment);
        while (self.cursor < self.input.len) : (self.cursor += 1) {
            switch (self.input[self.cursor]) {
                '\n' => {
                    self.line_number += 1;
                    self.line_start_cursor = self.cursor;
                    self.in_comment = false;
                    break;
                },
                else => continue,
            }
        }
    }
};

/// Wrapper around a reader that scans and produces entries.
pub fn Reader(comptime buf_size: usize, comptime ReaderType: type) type {
    return struct {
        buf: [buf_size]u8 = undefined,
        scanner: Scanner = Scanner.init(),
        reader: ReaderType,

        pub const Error = ReaderType.Error || Scanner.Error || Allocator.Error;

        pub fn init(reader: ReaderType) @This() {
            return @This(){ .reader = reader };
        }

        pub fn deinit(self: *@This()) void {
            // TODO: close reader?
            self.scanner.deinit();
            self.* = undefined;
        }

        pub fn parse_all(self: *@This(), alloc: Allocator) Error!std.ArrayList(Entry) {
            var entries = std.ArrayList(Entry).init(alloc);
            errdefer entries.deinit();
            while (try self.next_entry(alloc)) |entry| {
                try entries.append(entry);
            }
            return entries;
        }

        fn next_scanner_token(self: *@This()) Error!Scanner.Token {
            while (true) {
                return self.scanner.next() catch |err| switch (err) {
                    error.BufferUnderrun => {
                        const n = try self.reader.read(self.buf[0..]);
                        if (n == 0) {
                            self.scanner.end_input();
                        } else {
                            self.scanner.feed(self.buf[0..n]);
                        }
                        continue;
                    },
                    else => |e| return e,
                };
            }
        }

        fn next_entry(self: *@This(), alloc: Allocator) Error!?Entry {
            const String = std.ArrayList(u8);

            switch (try self.next_scanner_token()) {
                .entry_begin => {},
                .end_document => return null,
                else => unreachable,
            }

            assert(try self.next_scanner_token() == .type_begin);
            var typ = try String.initCapacity(alloc, 16);

            while (true) {
                errdefer typ.deinit();
                switch (try self.next_scanner_token()) {
                    .type_partial => |t| try typ.appendSlice(t),
                    .type_end => break,
                    else => unreachable,
                }
            }

            var entry = Entry.init(alloc, try alloc.dupe(u8, typ.items));
            typ.deinit();
            errdefer entry.deinit();

            while (true) {
                switch (try self.next_scanner_token()) {
                    .tag_begin => {},
                    .entry_end => break,
                    else => unreachable,
                }

                var tag = try String.initCapacity(alloc, 16);
                var tag_tok = try self.next_scanner_token();
                defer tag.deinit();

                while (tag_tok == .tag_partial) {
                    try tag.appendSlice(tag_tok.tag_partial);
                    tag_tok = try self.next_scanner_token();
                }

                tag.shrinkAndFree(tag.items.len);

                switch (tag_tok) {
                    .tag_end => {},
                    .tag_end_no_value => {
                        try entry.push(tag.items, null);
                        continue;
                    },
                    .tag_and_entry_end => {
                        try entry.push(tag.items, null);
                        break;
                    },
                    else => unreachable,
                }

                assert(try self.next_scanner_token() == .value_begin);
                var value = try String.initCapacity(alloc, 16);
                var value_tok = try self.next_scanner_token();
                defer value.deinit();

                while (value_tok == .value_partial) {
                    try value.appendSlice(value_tok.value_partial);
                    value_tok = try self.next_scanner_token();
                }

                value.shrinkAndFree(value.items.len);
                try entry.push(tag.items, value.items);

                switch (value_tok) {
                    .value_end => continue,
                    .value_and_entry_end => break,
                    else => unreachable,
                }
            }

            return entry;
        }
    };
}

const Entry = struct {
    const Pair = struct {
        tag: []const u8,
        value: ?[]const u8,
    };

    alloc: std.mem.Allocator,
    typ: []const u8,
    elems: std.ArrayList(Pair),

    const Self = @This();

    /// Creates a new entry. `typ` is owned and must be allocated with `alloc`.
    fn init(
        alloc: std.mem.Allocator,
        typ: []const u8,
    ) Self {
        return Self{
            .typ = typ,
            .alloc = alloc,
            .elems = std.ArrayList(Pair).init(alloc),
        };
    }

    fn push(self: *Self, tag: []const u8, value: ?[]const u8) !void {
        const tag_ = try self.alloc.dupe(u8, tag);
        var value_: ?[]const u8 = null;
        if (value) |v| {
            value_ = try self.alloc.dupe(u8, v);
        }
        try self.elems.append(.{ .tag = tag_, .value = value_ });
    }

    fn deinit(self: *Self) void {
        for (self.elems.items) |pair| {
            self.alloc.free(pair.tag);
            if (pair.value) |v| {
                self.alloc.free(v);
            }
        }
        self.elems.deinit();
        self.alloc.free(self.typ);
    }

    fn pretty_print(self: *const Self, writer: anytype) @TypeOf(writer).Error!void {
        try writer.writeAll("@");
        try writer.writeAll(self.typ);
        try writer.writeAll("{\n");

        for (self.elems.items) |pair| {
            try writer.writeAll("  ");
            try writer.writeAll(pair.tag);
            if (pair.value) |v| {
                try writer.writeAll(" = ");
                try writer.writeAll("{");
                try writer.writeAll(v);
                try writer.writeAll("},\n");
            } else {
                try writer.writeAll(",\n");
            }
        }

        try writer.writeAll("}\n");
    }
};

test "it fucking works" {
    const test_str =
        \\@article{
        \\  other_new_1955,
        \\  % comment
        \\  title = "A new method for the determination of the pressure of gases",
        \\  author = {A. N. Other},
        \\  journal = {The Journal of Chemical Physics},
        \\  volume={81},
        \\  number={{10}},
        \\  pages={1000--{1001}},
        \\  year = "1955",
        \\  publisher="{American {Chemical}} Society"
        \\  % comment
        \\}
    ;

    var scan = Scanner.init();
    scan.feed(test_str);
    scan.end_input();
    while (true) {
        switch (try scan.next()) {
            .type_partial => |t| std.debug.print("{s}\n", .{t}),
            .tag_partial => |t| std.debug.print("{s}\n", .{t}),
            .value_partial => |t| std.debug.print("{s}\n", .{t}),
            .end_document => break,
            else => |c| std.debug.print("{any}\n", .{c}),
        }
    }

    var stream = std.io.fixedBufferStream(test_str);
    var reader = Reader(1024, @TypeOf(stream.reader())).init(stream.reader());

    var entries = try reader.parse_all(std.testing.allocator);
    defer {
        for (entries.items) |*entry| {
            entry.deinit();
        }
        entries.deinit();
    }

    for (entries.items) |entry| {
        try entry.pretty_print(std.io.getStdOut().writer());
    }
}
