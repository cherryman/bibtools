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

fn skipws(str: *[]const u8) void {
    for (str.*, 0..) |c, i| {
        if (!ascii.isWhitespace(c)) {
            str.* = str.*[i..];
            return;
        }
    }
    str.* = str.*[str.*.len..];
}

// fn parsetok(str: []const u8) struct { tok: ?[]const u8, rst: []const u8 } {
//     for (str, 0..) |c, i| {
//         if (!ascii.isAlphabetic(c)) {
//             return .{ .tok = str[0..i], .rst = str[i..] };
//         }
//
//         // TODO handle not ascii
//         // TODO handle all other shit
//     }
//     return .{ .tok = null, .rst = str[str.len..] };
// }

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

        // TODO: duplicate keys
        // TODO: lowercase keys

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
        // TODO: comments
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
}
