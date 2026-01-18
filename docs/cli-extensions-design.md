# CLI Infrastructure Extensions Design

## Context

The pluckz project encountered three limitations when integrating with
termcat.cli that required manual workarounds. This document analyzes these
limitations and proposes extensions.

**Source**: pluckz/src/cli/cli.zig partial integration pattern

## Limitation 1: No Default Command

### Problem

`parseApp()` requires an explicit command name. Apps with a "default mode" (no
subcommand = run main functionality) must handle this manually.

**Current behavior** (Parser.zig:688-691):

```zig
if (i >= args.len) {
    return .{ .err = CliError.usageError("missing command") };
}
```

**Workaround**: pluckz checks for `auth` subcommand first, then falls back to
`Parser.parse()` for GlobalOptions only.

### Proposed Solution

Add optional `default_command` declaration:

```zig
pub const MyApp = struct {
    pub const meta = .{ .name = "myapp" };
    pub const GlobalOptions = struct { verbose: bool = false };

    // NEW: Default command when no subcommand provided
    pub const default_command: []const u8 = "run";

    pub const Command = cli.Commands(.{
        .run = RunCommand,
        .config = ConfigCommand,
    });
};
```

**Implementation** in parseApp():

```zig
if (i >= args.len) {
    // Check for default_command declaration
    if (@hasDecl(App, "default_command")) {
        const cmd_name = App.default_command;
        // Dispatch to default command with empty args
        // ... existing command dispatch logic ...
    } else {
        return .{ .err = CliError.usageError("missing command") };
    }
}
```

### Alternative: Implicit Default

If no command is provided AND `GlobalOptions` has positional fields, parse those
directly:

```zig
pub const GlobalOptions = struct {
    verbose: bool = false,
    files: VariadicPositional([]const u8),  // See Limitation 2

    pub const positional = .{.files};
};
```

This is more complex but matches pluckz's actual need.

---

## Limitation 2: No Variable Positional Arguments

### Problem

Commands can only declare fixed positional arguments. Variable-length
positionals like `[files...]` require pre-filtering args before parsing.

**Current behavior** (Parser.zig:203-204):

```zig
} else {
    return .{ .err = CliError.usageError("unexpected argument").withContext(arg) };
}
```

**Workaround**: pluckz pre-filters file arguments into a separate ArrayList
before calling `Parser.parse()`.

### Proposed Solution A: Variadic Marker Type

Introduce a marker type that signals "collect remaining args":

```zig
pub const Command = struct {
    output: []const u8,
    files: cli.Variadic([]const u8),  // Collects all remaining positionals

    pub const positional = .{ .output, .files };  // files must be last

    pub const fields = .{
        .output = .{ .description = "Output file" },
        .files = .{ .description = "Input files" },
    };
};
```

**Variadic type definition**:

```zig
pub fn Variadic(comptime T: type) type {
    return struct {
        items: []const T,

        pub const is_variadic = true;
        pub const ItemType = T;
    };
}
```

**Parser changes**:

```zig
// In parse(), when processing positionals:
if (positional_index < positional_fields.len) {
    const field_name = positional_fields[positional_index];

    if (isVariadicField(T, field_name)) {
        // Collect ALL remaining positional args
        var variadic_items = std.ArrayList(FieldItemType).init(allocator);
        variadic_items.append(arg);
        while (i + 1 < args.len and !isOption(args[i + 1])) {
            i += 1;
            variadic_items.append(args[i]);
        }
        setVariadicField(&result, field_name, variadic_items.items);
    } else {
        // Existing single-value logic
    }
}
```

### Proposed Solution B: Trailing Slice Convention

Simpler approach: if the last positional is `[][]const u8`, treat it as
variadic:

```zig
pub const Command = struct {
    output: []const u8,
    files: [][]const u8,  // Last positional = variadic

    pub const positional = .{ .output, .files };
};
```

**Pros**: No new types needed **Cons**: Less explicit, requires allocation

### Allocation Consideration

Both solutions require runtime allocation for the slice. Options:

1. Require allocator parameter to `parse()`
2. Use bounded array: `files: std.BoundedArray([]const u8, 256)`
3. Return indices into original args slice (zero-copy but less ergonomic)

**Recommendation**: Add optional allocator parameter with bounded array
fallback:

```zig
pub fn parse(comptime T: type, args: []const []const u8) ParseResult(T) { ... }
pub fn parseAlloc(comptime T: type, args: []const []const u8, allocator: Allocator) ParseResultAlloc(T) { ... }
```

---

## Limitation 3: Help Without parseApp()

### Problem

Auto-generated help via `Help.zig` is designed for parseApp() integration.
Commands that use `parse()` directly lose help generation.

**Workaround**: pluckz has manual `printHelp()` function duplicating termcat.cli
knowledge.

### Proposed Solution

Add standalone help generation for single commands:

```zig
// Already exists: generateHelp(T) for command types
// Add: utility that combines parse + help handling

pub fn parseWithHelp(
    comptime T: type,
    args: []const []const u8,
    writer: anytype,
    comptime options: struct {
        app_name: []const u8 = "",
        include_version: bool = true,
    },
) union(enum) {
    ok: T,
    err: CliError,
    handled: void,  // Help/version was printed
} {
    const result = parse(T, args);
    switch (result) {
        .help => {
            const help_text = Help.generateHelp(T);
            writer.writeAll(help_text);
            return .handled;
        },
        .version => {
            if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), "version")) {
                writer.print("{s} {s}\n", .{options.app_name, T.meta.version});
            }
            return .handled;
        },
        .ok => |v| return .{ .ok = v },
        .err => |e| return .{ .err = e },
    }
}
```

### App-Level Help for Non-parseApp Usage

For apps that manually dispatch commands but want unified help:

```zig
pub fn generateAppHelpManual(
    comptime GlobalOptions: type,
    comptime commands: anytype,  // Tuple of command types
    comptime meta: AppMeta,
) []const u8 { ... }
```

---

## Implementation Priority

| Extension                 | Complexity | Impact | Priority |
| ------------------------- | ---------- | ------ | -------- |
| Default command           | Low        | Medium | P2       |
| Variadic positionals      | Medium     | High   | P1       |
| Standalone help utilities | Low        | Medium | P2       |

**Recommendation**: Start with variadic positionals (P1) as it addresses the
most common CLI pattern (multiple input files).

---

## Alternatives Considered

### 1. External Args Pre-processing

Keep termcat.cli minimal, expect callers to pre-filter args. This is what pluckz
does today.

**Rejected**: Too much boilerplate, easy to get wrong (short option value
consumption, `--` handling).

### 2. REST-style Subcommands Only

Require all CLIs to use explicit subcommands (e.g., `git add`, not `git` with
implied add).

**Rejected**: Doesn't match common CLI conventions (compilers, interpreters).

### 3. Callback-based Parsing

Replace declarative parsing with callbacks that handle remaining args.

**Rejected**: Loses type-safety and comptime benefits.

---

## Disambiguation Rules

### Subcommand vs Positional Conflict

When default command is enabled and a positional argument matches a subcommand
name:

```
myapp auth          # Is this subcommand 'auth' or file named 'auth'?
```

**Resolution**: Subcommands take precedence. To pass a file named like a
subcommand:

```
myapp -- auth       # Explicit: treat 'auth' as positional
myapp ./auth        # Path prefix disambiguates
```

**Implementation**: Check subcommand match BEFORE falling back to default
command:

```zig
// In parseApp():
if (i >= args.len) {
    // No args at all -> default command with empty positionals
    return dispatchDefault(App, global, &.{});
}

const first_arg = args[i];

// 1. Try explicit subcommand match first
inline for (union_info.@"union".fields) |field| {
    if (std.mem.eql(u8, field.name, first_arg)) {
        return dispatchCommand(field, args[i+1..], global);
    }
}

// 2. No subcommand match -> default command gets ALL remaining args
if (@hasDecl(App, "default_command")) {
    return dispatchDefault(App, global, args[i..]);
}

return .{ .err = CliError.usageError("unknown command").withContext(first_arg) };
```

### End-of-Options (`--`) Handling

The `--` separator signals "all following args are positional, not options":

```
myapp --verbose -- --file-starting-with-dash.txt -another-file.txt
```

**Current state**: `parseApp()` handles `--` (Parser.zig:596-599), but base
`parse()` does not.

**Required change**: Add `--` handling to `parse()` for variadic positionals:

```zig
// In parse(), add to main loop:
if (std.mem.eql(u8, arg, "--")) {
    // Collect all remaining args as positionals
    for (args[i+1..]) |remaining| {
        if (positional_index < positional_fields.len) {
            // ... assign to positional field
        }
    }
    break;
}
```

---

## Zero-Allocation Variadic Approach

Instead of allocating a new slice, return indices into the original `args`
array:

```zig
pub const VariadicSlice = struct {
    start: usize,
    end: usize,

    pub fn items(self: @This(), args: []const []const u8) []const []const u8 {
        return args[self.start..self.end];
    }
};

pub const Command = struct {
    output: []const u8,
    files: VariadicSlice,  // Zero-copy reference

    pub const positional = .{ .output, .files };
};
```

**Usage**:

```zig
const result = parse(Command, args);
const files = result.files.items(args);  // Caller provides original args
```

**Tradeoffs**:

| Approach        | Allocation | Ergonomics    | Lifetime     |
| --------------- | ---------- | ------------- | ------------ |
| `[][]const u8`  | Yes        | Natural slice | Owned        |
| `VariadicSlice` | No         | Extra call    | Tied to args |
| `BoundedArray`  | No (stack) | Limited size  | Owned        |

**Recommendation**: Offer both. Default to `VariadicSlice` for zero-copy, add
`parseAlloc()` for owned slice.

---

## Help Generation Updates

### Default Command Display

When `default_command` is declared, help should show:

```
Usage: myapp [OPTIONS] [FILES...]       (default mode)
       myapp <command> [OPTIONS]        (subcommand mode)

Commands:
  run      Run the application (default)
  config   Manage configuration
```

**Implementation**: Check for `default_command` in `generateAppHelp()`:

```zig
if (@hasDecl(App, "default_command")) {
    // Find default command's positionals for usage line
    const default_cmd = getCommandByName(App.Command, App.default_command);
    const positionals = getPositionalUsage(default_cmd);
    try writer.print("Usage: {s} [OPTIONS] {s}\n", .{meta.name, positionals});
    try writer.print("       {s} <command> [OPTIONS]\n\n", .{meta.name});
} else {
    try writer.print("Usage: {s} <command> [OPTIONS]\n\n", .{meta.name});
}
```

### Variadic Positional Display

Variadic fields display with `...` suffix:

```
Arguments:
  <output>    Output file
  <files>...  Input files (one or more)
```

**Implementation**: Detect variadic in `generateHelp()`:

```zig
if (isVariadicField(T, field.name)) {
    try writer.print("  <{s}>...  {s}\n", .{field.name, spec.description});
} else {
    try writer.print("  <{s}>     {s}\n", .{field.name, spec.description});
}
```

---

## Implementation Notes

### VariadicSlice Index Semantics

`VariadicSlice` stores indices relative to the args slice passed to `parse()`.
When using `parseApp()`, the result includes a `cmd_args` field containing the
correct slice:

```zig
const result = parseApp(MyApp, args);
switch (result) {
    .ok => |r| {
        // CORRECT: Use cmd_args for VariadicSlice.items()
        const files = r.command.run.files.items(r.cmd_args);

        // WRONG: Don't use original args - indices will be off
        // const files = r.command.run.files.items(args);
    },
    // ...
}
```

For direct `parse()` calls, use the same args slice you passed to parse:

```zig
const result = parse(MyCmd, args);
switch (result) {
    .ok => |cmd| {
        const files = cmd.files.items(args);  // Same args passed to parse()
    },
    // ...
}
```

### Subcommand Groups

For subcommand groups (e.g., `app bib add file1.bib file2.bib`), the `cmd_args`
slice is correctly propagated through the nested parsing:

```zig
const result = parseApp(MyApp, &.{ "bib", "add", "out.bib", "file1.bib", "file2.bib" });
switch (result) {
    .ok => |r| {
        // cmd_args = ["out.bib", "file1.bib", "file2.bib"]
        // (the slice passed to the innermost parse() call)
        const files = r.command.bib.value.add.files.items(r.cmd_args);
    },
    // ...
}
```

The `parseSubcommandGroup()` function returns both the parsed command and the
args slice used for parsing, ensuring `VariadicSlice` indices work correctly
regardless of nesting depth.

---

## Open Questions

1. **Allocator threading**: Should parseAlloc return an arena that caller must
   free, or individual allocations?

2. **Help customization**: How much should generated help be customizable
   (section order, formatting)?

3. **Error context for variadics**: How to report errors in variadic args (which
   file failed to validate)?

4. **Minimum variadic count**: Should variadic support
   `files: Variadic([]const u8, .{.min = 1})` for "at least one required"?
