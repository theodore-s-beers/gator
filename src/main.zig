const std = @import("std");
const later = @import("later");
const zbench = @import("zbench");

pub const panic = std.debug.no_panic; // Don't unwind; faster

const BenchmarkState = struct {
    alloc: std.mem.Allocator,
    coll: later.Collator,
    text: []u8,
    list: std.ArrayList([]const u8),
    list_orig: [][]const u8,
};

var bench_state: ?*BenchmarkState = null;

pub fn main() !void {
    const alloc = std.heap.smp_allocator;

    //
    // Conformance tests
    //

    var coll = try later.Collator.init(alloc, .ducet, false, false);
    defer coll.deinit();

    conformance(alloc, "test-data/CollationTest_NON_IGNORABLE_SHORT.txt", &coll);

    coll = try later.Collator.init(alloc, .ducet, true, false);
    conformance(alloc, "test-data/CollationTest_SHIFTED_SHORT.txt", &coll);

    coll = try later.Collator.init(alloc, .cldr, false, false);
    conformance(alloc, "test-data/CollationTest_CLDR_NON_IGNORABLE_SHORT.txt", &coll);

    coll = try later.Collator.init(alloc, .cldr, true, false);
    conformance(alloc, "test-data/CollationTest_CLDR_SHIFTED_SHORT.txt", &coll);

    //
    // Zauberberg benchmark
    //

    var bench = zbench.Benchmark.init(alloc, .{});
    defer bench.deinit();

    try bench.add("Zauberberg sorting", benchZauberbergSorting, .{
        .track_allocations = true,
        .hooks = .{
            .before_all = setupBenchState,
            .before_each = resetListOrder,
            .after_all = cleanupBenchState,
        },
    });

    var file_writer = std.fs.File.stdout().writer(&.{});
    try file_writer.interface.writeAll("\n");
    try bench.run(&file_writer.interface);
}

fn conformance(alloc: std.mem.Allocator, path: []const u8, coll: *later.Collator) void {
    const start_time = std.time.microTimestamp();
    defer {
        const end_time = std.time.microTimestamp();
        const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000.0;
        std.debug.print("{s}: {d:.2}ms\n", .{ path, duration_ms });
    }

    const test_data = std.fs.cwd().readFileAlloc(alloc, path, 4 * 1024 * 1024) catch unreachable;
    defer alloc.free(test_data);

    var max_line = std.ArrayList(u8).initCapacity(alloc, 32) catch unreachable;
    defer max_line.deinit(alloc);

    var test_string = std.ArrayList(u8).initCapacity(alloc, 32) catch unreachable;
    defer test_string.deinit(alloc);

    var line_iter = std.mem.splitScalar(u8, test_data, '\n');
    var i: usize = 0;

    outer: while (line_iter.next()) |line| {
        i += 1;
        if (line.len == 0 or line[0] == '#') continue;

        test_string.clearRetainingCapacity();

        var word_iter = std.mem.splitScalar(u8, line, ' ');
        while (word_iter.next()) |hex| {
            const val = std.fmt.parseInt(u32, hex, 16) catch unreachable;
            if (0xD800 <= val and val <= 0xDFFF) continue :outer; // Surrogate code points

            var utf8_bytes: [4]u8 = undefined;
            const len = utf8Encode(@intCast(val), &utf8_bytes);
            test_string.appendSliceAssumeCapacity(utf8_bytes[0..len]);
        }

        const comparison = coll.collate(test_string.items, max_line.items);
        if (comparison == .lt) std.debug.panic("Invalid collation order at line {}\n", .{i});

        std.mem.swap(std.ArrayList(u8), &max_line, &test_string);
    }
}

fn utf8Encode(c: u21, out: []u8) u3 {
    const length: u3 = if (c < 0x80) 1 else if (c < 0x800) 2 else if (c < 0x10000) 3 else 4;

    switch (length) {
        1 => out[0] = @as(u8, @intCast(c)),
        2 => {
            out[0] = @as(u8, @intCast(0b11000000 | (c >> 6)));
            out[1] = @as(u8, @intCast(0b10000000 | (c & 0b111111)));
        },
        3 => {
            out[0] = @as(u8, @intCast(0b11100000 | (c >> 12)));
            out[1] = @as(u8, @intCast(0b10000000 | ((c >> 6) & 0b111111)));
            out[2] = @as(u8, @intCast(0b10000000 | (c & 0b111111)));
        },
        4 => {
            out[0] = @as(u8, @intCast(0b11110000 | (c >> 18)));
            out[1] = @as(u8, @intCast(0b10000000 | ((c >> 12) & 0b111111)));
            out[2] = @as(u8, @intCast(0b10000000 | ((c >> 6) & 0b111111)));
            out[3] = @as(u8, @intCast(0b10000000 | (c & 0b111111)));
        },
        else => unreachable,
    }

    return length;
}

fn benchZauberbergSorting(alloc: std.mem.Allocator) void {
    _ = alloc;

    if (bench_state) |state| {
        std.mem.sortUnstable([]const u8, state.list.items, &state.coll, later.collateComparator);
    }
}

fn setupBenchState() void {
    const alloc = std.heap.smp_allocator;

    bench_state = alloc.create(BenchmarkState) catch unreachable;
    bench_state.?.alloc = alloc;

    bench_state.?.text =
        std.fs.cwd().readFileAlloc(alloc, "test-data/zauberberg.txt", 64 * 1024) catch unreachable;
    bench_state.?.list = std.ArrayList([]const u8).empty;

    var it = std.mem.tokenizeAny(u8, bench_state.?.text, " \t\n\r");
    while (it.next()) |token| bench_state.?.list.append(alloc, token) catch unreachable;

    bench_state.?.coll = later.Collator.init(alloc, .cldr, false, false) catch unreachable;
    bench_state.?.list_orig = alloc.dupe([]const u8, bench_state.?.list.items) catch unreachable;
}

fn resetListOrder() void {
    if (bench_state) |state| @memcpy(state.list.items, state.list_orig);
}

fn cleanupBenchState() void {
    if (bench_state) |state| {
        state.alloc.free(state.text);
        state.alloc.free(state.list_orig);
        state.list.deinit(state.alloc);
        state.coll.deinit();

        state.alloc.destroy(state);
        bench_state = null;
    }
}
