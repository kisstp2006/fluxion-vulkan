// SPDX-License-Identifier: BSL-1.0

//! A small, strict XML reader: exactly as much XML as the Vulkan registry uses.
//!
//! `vk.xml` is regular. It has elements, double-quoted attributes, text, comments,
//! one `<?xml ...?>` declaration and the five predefined entities, and that is
//! all this reads. Anything else - a DOCTYPE, CDATA, a namespace prefix, a
//! single-quoted attribute, an entity it does not know, an element that is not
//! closed by the tag that opened it - is `error.Syntax` with a line and column,
//! because a generator that guesses at what it does not understand writes wrong
//! ABI without telling anyone.
//!
//! The tree lives in the arena it was parsed into. Text is kept in order beside
//! the elements, because the registry writes C declarations as mixed content:
//! `const <type>char</type>* <name>pName</name>` is text, an element, text, an
//! element.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Child = union(enum) {
    element: *Node,
    text: []const u8,
};

pub const Node = struct {
    tag: []const u8,
    attrs: []const Attr,
    children: []const Child,

    /// The value of an attribute, or null when it is not there.
    pub fn attr(self: *const Node, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }

    /// The first child element with this tag.
    pub fn child(self: *const Node, tag: []const u8) ?*Node {
        for (self.children) |c| switch (c) {
            .element => |e| if (std.mem.eql(u8, e.tag, tag)) return e,
            .text => {},
        };
        return null;
    }

    /// Iterates the child elements, skipping the text between them.
    pub fn elements(self: *const Node) Elements {
        return .{ .children = self.children };
    }

    pub const Elements = struct {
        children: []const Child,
        index: usize = 0,

        pub fn next(self: *Elements) ?*Node {
            while (self.index < self.children.len) {
                const c = self.children[self.index];
                self.index += 1;
                switch (c) {
                    .element => |e| return e,
                    .text => {},
                }
            }
            return null;
        }
    };

    /// All the text under this node, concatenated, with element tags dropped.
    /// The registry's `<name>` and `<type>` elements hold nothing but text, so
    /// this is how their content is read.
    pub fn textContent(self: *const Node, arena: Allocator) Allocator.Error![]const u8 {
        var list: std.ArrayList(u8) = .empty;
        try self.collectText(arena, &list);
        return list.items;
    }

    fn collectText(self: *const Node, arena: Allocator, list: *std.ArrayList(u8)) Allocator.Error!void {
        for (self.children) |c| switch (c) {
            .text => |t| try list.appendSlice(arena, t),
            .element => |e| try e.collectText(arena, list),
        };
    }
};

/// Where a parse went wrong, for the message.
pub const Diagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",

    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}: {s}", .{ self.line, self.column, self.message });
    }
};

pub const Error = Allocator.Error || error{Syntax};

/// Parse a document into `arena`. `diagnostic`, when given, says where a
/// `error.Syntax` was found.
pub fn parse(arena: Allocator, source: []const u8, diagnostic: ?*Diagnostic) Error!*Node {
    var parser: Parser = .{ .arena = arena, .source = source, .diagnostic = diagnostic };
    return parser.document();
}

const Parser = struct {
    arena: Allocator,
    source: []const u8,
    pos: usize = 0,
    diagnostic: ?*Diagnostic,

    fn fail(self: *Parser, message: []const u8) error{Syntax} {
        if (self.diagnostic) |d| {
            var line: usize = 1;
            var column: usize = 1;
            for (self.source[0..@min(self.pos, self.source.len)]) |c| {
                if (c == '\n') {
                    line += 1;
                    column = 1;
                } else column += 1;
            }
            d.* = .{ .line = line, .column = column, .message = message };
        }
        return error.Syntax;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.source.len) self.source[self.pos] else null;
    }

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.source[self.pos..], prefix);
    }

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.source.len) : (self.pos += 1) {
            switch (self.source[self.pos]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn document(self: *Parser) Error!*Node {
        // A byte order mark is the one thing allowed before the declaration.
        if (self.startsWith("\xEF\xBB\xBF")) self.pos += 3;
        self.skipSpace();
        if (self.startsWith("<?xml")) try self.skipUntil("?>", "an unterminated <?xml declaration");
        try self.skipMisc();

        if (self.peek() != '<') return self.fail("expected the root element");
        const root = try self.element();

        try self.skipMisc();
        if (self.pos != self.source.len) return self.fail("content after the root element");
        return root;
    }

    /// Whitespace and comments, which are allowed between anything.
    fn skipMisc(self: *Parser) Error!void {
        while (true) {
            self.skipSpace();
            if (self.startsWith("<!--")) {
                try self.comment();
            } else if (self.startsWith("<?")) {
                return self.fail("processing instructions are not supported");
            } else if (self.startsWith("<!")) {
                return self.fail("DOCTYPE and CDATA are not supported");
            } else return;
        }
    }

    fn skipUntil(self: *Parser, terminator: []const u8, what: []const u8) Error!void {
        const found = std.mem.indexOfPos(u8, self.source, self.pos, terminator) orelse
            return self.fail(what);
        self.pos = found + terminator.len;
    }

    fn comment(self: *Parser) Error!void {
        self.pos += "<!--".len;
        const end = std.mem.indexOfPos(u8, self.source, self.pos, "-->") orelse
            return self.fail("an unterminated comment");
        // XML forbids a double hyphen inside a comment, and a reader that lets
        // it through is a reader that misparses the next thing.
        if (std.mem.indexOf(u8, self.source[self.pos..end], "--") != null)
            return self.fail("a double hyphen inside a comment");
        self.pos = end + "-->".len;
    }

    fn name(self: *Parser) Error![]const u8 {
        const start = self.pos;
        while (self.pos < self.source.len) : (self.pos += 1) {
            switch (self.source[self.pos]) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
                ':' => return self.fail("namespace prefixes are not supported"),
                else => break,
            }
        }
        if (self.pos == start) return self.fail("expected a name");
        switch (self.source[start]) {
            'a'...'z', 'A'...'Z', '_' => {},
            else => {
                self.pos = start;
                return self.fail("a name must start with a letter");
            },
        }
        return self.source[start..self.pos];
    }

    fn element(self: *Parser) Error!*Node {
        std.debug.assert(self.peek() == '<');
        self.pos += 1;
        const tag = try self.name();

        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            self.skipSpace();
            const c = self.peek() orelse return self.fail("an unterminated tag");
            if (c == '>' or c == '/') break;

            const attr_name = try self.name();
            for (attrs.items) |seen| {
                if (std.mem.eql(u8, seen.name, attr_name)) return self.fail("a repeated attribute");
            }
            self.skipSpace();
            if (self.peek() != '=') return self.fail("expected '=' after an attribute name");
            self.pos += 1;
            self.skipSpace();
            if (self.peek() != '"') return self.fail("attribute values must be double-quoted");
            self.pos += 1;
            const end = std.mem.indexOfScalarPos(u8, self.source, self.pos, '"') orelse
                return self.fail("an unterminated attribute value");
            const raw = self.source[self.pos..end];
            if (std.mem.indexOfScalar(u8, raw, '<') != null) return self.fail("'<' inside an attribute value");
            const value = try self.decode(raw);
            try attrs.append(self.arena, .{ .name = attr_name, .value = value });
            self.pos = end + 1;
        }

        const node = try self.arena.create(Node);
        node.* = .{ .tag = tag, .attrs = attrs.items, .children = &.{} };

        if (self.peek() == '/') {
            self.pos += 1;
            if (self.peek() != '>') return self.fail("expected '>' after '/'");
            self.pos += 1;
            return node;
        }
        self.pos += 1; // '>'

        var children: std.ArrayList(Child) = .empty;
        while (true) {
            const text_end = std.mem.indexOfScalarPos(u8, self.source, self.pos, '<') orelse
                return self.fail("an element that is never closed");
            if (text_end > self.pos) {
                const text = try self.decode(self.source[self.pos..text_end]);
                try children.append(self.arena, .{ .text = text });
            }
            self.pos = text_end;

            if (self.startsWith("<!--")) {
                try self.comment();
            } else if (self.startsWith("</")) {
                self.pos += 2;
                const closing = try self.name();
                if (!std.mem.eql(u8, closing, tag)) return self.fail("a closing tag that does not match its opening tag");
                self.skipSpace();
                if (self.peek() != '>') return self.fail("expected '>' in a closing tag");
                self.pos += 1;
                break;
            } else if (self.startsWith("<?")) {
                return self.fail("processing instructions are not supported");
            } else if (self.startsWith("<!")) {
                return self.fail("DOCTYPE and CDATA are not supported");
            } else {
                const inner = try self.element();
                try children.append(self.arena, .{ .element = inner });
            }
        }
        node.children = children.items;
        return node;
    }

    /// Resolve the predefined entities and numeric references. Returns the
    /// input untouched, and without allocating, when there is nothing to do.
    fn decode(self: *Parser, raw: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;

        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '&') {
                try out.append(self.arena, raw[i]);
                i += 1;
                continue;
            }
            const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse
                return self.fail("an entity with no ';'");
            const entity = raw[i + 1 .. semi];
            if (std.mem.eql(u8, entity, "amp")) {
                try out.append(self.arena, '&');
            } else if (std.mem.eql(u8, entity, "lt")) {
                try out.append(self.arena, '<');
            } else if (std.mem.eql(u8, entity, "gt")) {
                try out.append(self.arena, '>');
            } else if (std.mem.eql(u8, entity, "quot")) {
                try out.append(self.arena, '"');
            } else if (std.mem.eql(u8, entity, "apos")) {
                try out.append(self.arena, '\'');
            } else if (entity.len > 1 and entity[0] == '#') {
                const digits = if (entity[1] == 'x') entity[2..] else entity[1..];
                const base: u8 = if (entity[1] == 'x') 16 else 10;
                const code = std.fmt.parseInt(u21, digits, base) catch
                    return self.fail("a character reference that is not a number");
                var buffer: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(code, &buffer) catch
                    return self.fail("a character reference that is not a code point");
                try out.appendSlice(self.arena, buffer[0..n]);
            } else return self.fail("an entity this reader does not know");
            i = semi + 1;
        }
        return out.items;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn parseTest(arena: Allocator, source: []const u8) !*Node {
    return parse(arena, source, null);
}

test "elements, attributes and text come back in order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try parseTest(arena,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<registry>
        \\    <!-- a comment -->
        \\    <member optional="true" len="count">const <type>char</type>* <name>pName</name></member>
        \\    <empty a="1" b="two"/>
        \\</registry>
    );
    try testing.expectEqualStrings("registry", root.tag);

    var it = root.elements();
    const member = it.next().?;
    try testing.expectEqualStrings("member", member.tag);
    try testing.expectEqualStrings("true", member.attr("optional").?);
    try testing.expectEqual(@as(?[]const u8, null), member.attr("missing"));

    // The mixed content keeps its order: text, element, text, element.
    try testing.expectEqual(@as(usize, 4), member.children.len);
    try testing.expectEqualStrings("const ", member.children[0].text);
    try testing.expectEqualStrings("type", member.children[1].element.tag);
    try testing.expectEqualStrings("* ", member.children[2].text);
    try testing.expectEqualStrings("pName", member.child("name").?.children[0].text);
    try testing.expectEqualStrings("const char* pName", try member.textContent(arena));

    const empty = it.next().?;
    try testing.expectEqualStrings("empty", empty.tag);
    try testing.expectEqual(@as(usize, 0), empty.children.len);
    try testing.expectEqualStrings("two", empty.attr("b").?);
    try testing.expectEqual(@as(?*Node, null), it.next());
}

test "entities are resolved, and only the ones that exist" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try parseTest(arena,
        \\<a v="&quot;x&quot; &amp; &lt;y&gt;">&#65;&#x42; &apos;</a>
    );
    try testing.expectEqualStrings("\"x\" & <y>", root.attr("v").?);
    try testing.expectEqualStrings("AB '", root.children[0].text);

    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.Syntax, parse(arena, "<a>&nbsp;</a>", &diagnostic));
    try testing.expectEqualStrings("an entity this reader does not know", diagnostic.message);
}

test "what it does not understand is an error with a place" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bad = [_]struct { source: []const u8, why: []const u8 }{
        .{ .source = "<a></b>", .why = "a closing tag that does not match its opening tag" },
        .{ .source = "<a>", .why = "an element that is never closed" },
        .{ .source = "<a b='1'/>", .why = "attribute values must be double-quoted" },
        .{ .source = "<a b=\"1\" b=\"2\"/>", .why = "a repeated attribute" },
        .{ .source = "<a><![CDATA[x]]></a>", .why = "DOCTYPE and CDATA are not supported" },
        .{ .source = "<!DOCTYPE a><a/>", .why = "DOCTYPE and CDATA are not supported" },
        .{ .source = "<a><?pi x?></a>", .why = "processing instructions are not supported" },
        .{ .source = "<x:a/>", .why = "namespace prefixes are not supported" },
        .{ .source = "<a/><b/>", .why = "content after the root element" },
        .{ .source = "<a><!-- x -- y --></a>", .why = "a double hyphen inside a comment" },
        .{ .source = "<a b=\"<\"/>", .why = "'<' inside an attribute value" },
    };
    for (bad) |case| {
        var diagnostic: Diagnostic = .{};
        try testing.expectError(error.Syntax, parse(arena, case.source, &diagnostic));
        try testing.expectEqualStrings(case.why, diagnostic.message);
    }

    // The position is a line and a column, counted from one.
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.Syntax, parse(arena, "<a>\n  <b>\n</a>", &diagnostic));
    try testing.expectEqual(@as(usize, 3), diagnostic.line);
}
