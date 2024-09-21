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
        post_member,
    };

    const Error = error{ SyntaxError, UnexpectedEndOfInput, UnexpectedChar };
    const NextError = Error || error{BufferUnderrun};

    const Token = union(enum) {
        part_type: []const u8,
        part_key: []const u8,
        end_key_no_value,
        end_key_with_value,
        part_value: []const u8,
        end_value,
        end,
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
                    switch (try self.skip_to_maybe_byte() orelse return .end) {
                        '@' => {
                            self.cursor += 1;
                            self.state = .saw_at;
                            continue;
                        },
                        else => return error.UnexpectedChar,
                    }
                },

                .saw_at => {
                    if (try self.skip_to_byte() == '{') {
                        return error.UnexpectedChar;
                    }
                    self.state = .entry_type;
                    continue;
                },

                // TODO: will need to handle comment or string set.
                // one approach: have a static array that can store
                // max(len("comment"), len("string")), dispatch on that,
                // don't return partial until we're sure it's neither.

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
                    return Token{ .part_type = self.input[i..self.cursor] };
                },

                .entry_post_type => {
                    switch (try self.skip_to_byte()) {
                        '{' => {
                            self.cursor += 1;
                            self.state = .pre_key;
                            continue;
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
                            continue;
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
                    return Token{ .part_key = self.input[i..self.cursor] };
                },

                .post_key => {
                    switch (try self.skip_to_byte()) {
                        ',' => {
                            self.cursor += 1;
                            self.state = .pre_key;
                            @panic("TODO");
                        },
                        '}' => {
                            self.cursor += 1;
                            self.state = .none;
                            @panic("TODO");
                        },
                        '=' => {
                            self.cursor += 1;
                            self.state = .pre_value;
                            continue;
                        },
                        ' ', '\n', '\t', '\r', '%' => {
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
                            continue;
                        },
                        '{' => {
                            self.cursor += 1;
                            self.state = .value_braced;
                            continue;
                        },
                        else => {
                            // TODO: handle variables
                            return error.UnexpectedChar;
                        },
                    }
                },

                .value_quoted => {
                    @panic("TODO");
                },

                .value_braced => {
                    @panic("TODO");
                },

                else => @panic("TODO"),
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

fn skipws(str: *[]const u8) void {
    for (str.*, 0..) |c, i| {
        if (!ascii.isWhitespace(c)) {
            str.* = str.*[i..];
            return;
        }
    }
    str.* = str.*[str.*.len..];
}

/// Parses an ascii encoded word.
fn parse_word(str: *[]const u8) ![]const u8 {
    const s = str.*;

    if (s.len == 0) {
        return error.UnexpectedEnd;
    }

    if (!ascii.isAlphabetic(s[0])) {
        return error.InvalidWord;
    }

    for (s[1..], 1..) |c, i| {
        if (!ascii.isAlphabetic(c) and !ascii.isDigit(c)) {
            str.* = str.*[i..];
            return s[0..i];
        }
    }

    return s[0..s.len];
}

// TODO: handle nested braces, ", numbers, variables, everything else.
fn parse_str(str: *[]const u8) ![]const u8 {
    const s = str.*;
    if (s.len == 0) {
        return error.UnexpectedEnd;
    }

    if (s[0] == '{') {
        if (s.len == 1) {
            return error.UnexpectedEnd;
        }

        for (s[1..], 1..) |c, i| {
            if (c == '}') {
                str.* = str.*[i + 1 ..];
                return s[1..i];
            }
        }

        return error.UnclosedBrace;
    }

    return error.UnexpectedChar;
}

// Consumes `<tag> = <value?> <,>?`
fn parse_tag_value(str: *[]const u8) !struct { tag: []const u8, value: ?[]const u8 } {
    const tag = try parse_word(str);
    skipws(str);

    if (str.*.len == 0) {
        return error.UnexpectedEnd;
    }

    if (str.*[0] == ',' or str.*[0] == '}') {
        return .{ .tag = tag, .value = null };
    }

    if (str.*[0] != '=') {
        return error.UnexpectedChar;
    }

    str.* = str.*[1..];
    skipws(str);

    if (str.*.len == 0) {
        return error.UnexpectedEnd;
    }

    const value = try parse_str(str);

    skipws(str);

    if (str.*.len == 0) {
        return error.UnexpectedEnd;
    }

    if (str.*[0] == '}') {
        // zig fmt r u ok
    } else if (str.*[0] == ',') {
        str.* = str.*[1..];
    } else {
        return error.UnexpectedChar;
    }

    return .{ .tag = tag, .value = value };
}

fn parse_entry(alloc: std.mem.Allocator, str: *[]const u8) !Entry {
    if (str.*.len == 0) {
        return error.UnexpectedEnd;
    }

    if (str.*[0] != '@') {
        return error.MissingAt;
    }

    str.* = str.*[1..];
    skipws(str);
    const key = try parse_word(str);
    skipws(str);

    if (str.*.len == 0) {
        return error.UnexpectedEnd;
    }

    if (str.*[0] != '{') {
        return error.MissingBrace;
    }

    str.* = str.*[1..];
    var entry = Entry.init(alloc, key);
    errdefer entry.deinit();

    skipws(str);
    while (str.*.len > 0) {
        const tag_value = try parse_tag_value(str);
        try entry.push(tag_value.tag, tag_value.value);

        skipws(str);

        if (str.*.len == 0) {
            return error.UnexpectedEnd;
        }

        if (str.*[0] == '}') {
            str.* = str.*[1..];
            break;
        }
    }

    return entry;
}

fn parse(alloc: std.mem.Allocator, s: []const u8) !std.ArrayList(Entry) {
    var str: []const u8 = s;
    var entries = std.ArrayList(Entry).init(alloc);

    errdefer {
        for (entries.items) |*entry| {
            entry.deinit();
        }
        entries.deinit();
    }

    skipws(&str);
    while (str.len > 0) {
        const entry = try parse_entry(alloc, &str);
        entries.append(entry) catch return error.Alloc;
        skipws(&str);
    }

    return entries;
}

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

// > The tag's name is not case-sensitive
//
// > There is a set of standard-tags existing, which can
// > be interpreted by BibTeX or third-party tools. Those
// > which are unknown are ignored by BibTeX, thus can be
// > used to store additional information without interfering
// > with the final outcome of a document.
//
// @ -> to lower single word -> { -> (to lower key = {text} or "text"),? -> }
//
// https://www.bibtex.org/Format/
// https://www.bibtex.org/SpecialSymbols/
//
// not official?
// https://www.bibtex.com/g/bibtex-format/
// https://tug.ctan.org/info/bibtex/tamethebeast/ttb_en.pdf
//
// some normalizations to do
// - enforce utf8
// - indentation
// - lowercase
// - line endings, last line empty
// - check keys are ascii
//
// TODO: fuzzing
// TODO: use reader

test "it fucking works" {
    const test_str =
        \\@article{
        // \\  title = "A new method for the determination of the pressure of gases",
        \\  author = {A. N. Other},
        \\  journal = {The Journal of Chemical Physics},
        \\  volume={81},
        \\  number={10},
        // \\  pages={1000--1001},
        // \\  year = 1955,
        \\  publisher={American Chemical Society}
        \\}
    ;

    const eql = std.mem.eql;
    const entries = try parse(std.testing.allocator, test_str);

    defer {
        for (entries.items) |*entry| {
            entry.deinit();
        }
        entries.deinit();
    }

    assert(entries.items.len == 1);
    const entry = entries.items[0];

    assert(eql(u8, entry.typ, "article"));
    assert(entry.elems.items.len == 5);

    assert(eql(u8, entry.elems.items[0].key, "author"));
    assert(eql(u8, entry.elems.items[0].value.?, "A. N. Other"));
    assert(eql(u8, entry.elems.items[1].key, "journal"));
    assert(eql(u8, entry.elems.items[1].value.?, "The Journal of Chemical Physics"));
    assert(eql(u8, entry.elems.items[2].key, "volume"));
    assert(eql(u8, entry.elems.items[2].value.?, "81"));
    assert(eql(u8, entry.elems.items[3].key, "number"));
    assert(eql(u8, entry.elems.items[3].value.?, "10"));
    assert(eql(u8, entry.elems.items[4].key, "publisher"));
    assert(eql(u8, entry.elems.items[4].value.?, "American Chemical Society"));

    var scan = Scanner.init();
    scan.feed(test_str);
    scan.end_input();
    while (true) {
        switch (try scan.next()) {
            .end => break,
            else => |c| std.debug.print("{any}\n", .{c}),
        }
    }
}
