const std = @import("std");
const assert = std.debug.assert;
const ascii = std.ascii;

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});
    try bw.flush(); // don't forget to flush!
}

/// Modelled after [`std.json.Scanner`] as it's idiomatic and is
/// approximately what I was going for. Here I cut and inlined some
/// stuff out since the syntax is somewhat simpler.
const Scanner = struct {
    const Self = @This();

    input: []const u8 = "",
    cursor: usize = 0,
    state: State = .none,
    is_end_of_input: bool = false,

    // TODO: taken from `Diagnostics`, need to use
    line_number: usize = 1,
    // line_start_cursor: usize = @as(usize, @bitCast(@as(isize, -1))),
    line_start_cursor: usize = 0,
    // total_bytes_before_current_input: usize = 0,
    // cursor_pointer: *const usize = undefined,

    // symbols: std.StringHashMap([]const u8),
    in_comment: bool = false,

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
        pre_key,
        key,
        post_key,
        pre_value,
        value_quoted,
        value_braced,
        post_value,
    };

    const Error = error{ SyntaxError, UnexpectedEndOfInput, UnexpectedChar };
    const NextError = Error || error{BufferUnderrun};

    const Token = union(enum) {
        entry_begin,
        type_begin,
        type_partial: []const u8,
        type_end,
        key_begin,
        key_partial: []const u8,
        key_end,
        key_and_entry_end,
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
    // TODO: duplicate keys
    // TODO: lowercase keys
    // TODO: early input handling
    // TODO: max lengths for idents
    // TODO: parentheses

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
                        else => return error.UnexpectedChar,
                    }
                },

                .saw_at => {
                    if (try self.skip_to_byte() == '{') {
                        return error.UnexpectedChar;
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
                            '0'...'9', 'a'...'z', 'A'...'Z', '_' => {
                                continue;
                            },
                            '{', ' ', '\n', '\t', '\r', '%' => {
                                self.state = .entry_post_type;
                                break;
                            },
                            else => return error.UnexpectedChar,
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
                            self.state = .pre_key;
                            return .type_end;
                        },
                        else => return error.UnexpectedChar,
                    }
                },

                .pre_key => {
                    switch (try self.skip_to_byte()) {
                        '}' => {
                            self.cursor += 1;
                            self.state = .none;
                            @panic("TODO");
                        },
                        '0'...'9', 'a'...'z', 'A'...'Z', '_' => {
                            self.state = .key;
                            return .key_begin;
                        },
                        else => {
                            return error.UnexpectedChar;
                        },
                    }
                },

                .key => {
                    // case should only be hit if we're at the start of a key.
                    const i = self.cursor;
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            '0'...'9', 'a'...'z', 'A'...'Z', '_' => {
                                continue;
                            },
                            else => {
                                self.state = .post_key;
                                break;
                            },
                        }
                    }
                    if (i == self.cursor) {
                        return error.BufferUnderrun;
                    }
                    return Token{ .key_partial = self.input[i..self.cursor] };
                },

                .post_key => {
                    switch (try self.skip_to_byte()) {
                        ',' => {
                            self.cursor += 1;
                            self.state = .pre_key;
                            return .key_end;
                        },
                        '}' => {
                            self.cursor += 1;
                            self.state = .none;
                            return .key_and_entry_end;
                        },
                        '=' => {
                            self.cursor += 1;
                            self.state = .pre_value;
                            continue;
                        },
                        else => return error.UnexpectedChar,
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
                            return error.UnexpectedChar;
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
                                @panic("TODO");
                            },
                            '}' => {
                                @panic("TODO");
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
                                // TODO: stack
                                self.state = .post_value;
                                break;
                            },
                            '{' => {
                                @panic("TODO");
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
                    switch (try self.skip_to_byte()) {
                        ',' => {
                            self.cursor += 1;
                            self.state = .pre_key;
                            return .value_end;
                        },
                        '}' => {
                            self.cursor += 1;
                            self.state = .none;
                            return .value_and_entry_end;
                        },
                        else => return error.UnexpectedChar,
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
                    continue;
                },
                else => continue,
            }
        }
    }
};

const Entry = struct {
    const Pair = struct {
        key: []const u8,
        value: ?[]const u8,
    };

    alloc: std.mem.Allocator,
    typ: []const u8,
    elems: std.ArrayList(Pair),

    const Self = @This();

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

    fn push(self: *Self, key: []const u8, value: ?[]const u8) !void {
        const key_ = try self.alloc.dupe(u8, key);
        var value_: ?[]const u8 = null;
        if (value) |v| {
            value_ = try self.alloc.dupe(u8, v);
        }
        try self.elems.append(.{ .key = key_, .value = value_ });
    }

    fn deinit(self: *Self) void {
        for (self.elems.items) |pair| {
            self.alloc.free(pair.key);
            if (pair.value) |v| {
                self.alloc.free(v);
            }
        }
        self.elems.deinit();
    }
};

test "it fucking works" {
    const test_str =
        \\@article{
        \\  title = "A new method for the determination of the pressure of gases",
        \\  author = {A. N. Other},
        \\  journal = {The Journal of Chemical Physics},
        \\  volume={81},
        \\  number={10},
        \\  pages={1000--1001},
        \\  year = {1955},
        \\  publisher={American Chemical Society}
        \\}
    ;

    var scan = Scanner.init();
    scan.feed(test_str);
    scan.end_input();
    while (true) {
        switch (try scan.next()) {
            .type_partial => |t| std.debug.print("{s}\n", .{t}),
            .key_partial => |t| std.debug.print("{s}\n", .{t}),
            .value_partial => |t| std.debug.print("{s}\n", .{t}),
            .end_document => break,
            else => |c| std.debug.print("{any}\n", .{c}),
        }
    }
}
