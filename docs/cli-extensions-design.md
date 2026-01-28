# CLI Infrastructure Extensions Design

Status: Draft
Last updated: 2026-01-28
Owner: termcat
Scope: termcat CLI parsing extensions
Related issues: workshop-3n72e9x, workshop-585hezx
References: None

## Summary

Design notes for termcat CLI extensions that originated from pluckz
integration gaps. The major extensions are now implemented; this document
captures the behavior, usage, and remaining open questions.

## Implementation status

- Default command: Implemented in `parseApp()` via `default_command`
  (Parser.zig:1042-1167).
- Variadic positionals: Implemented via `cli.Command.VariadicSlice` and parser
  support (Command.zig; Parser.zig:280-411).
- Standalone help: Implemented via `parseWithHelp()` and `Help.generateHelp()`
  (Parser.zig:88-114).

## Context

The pluckz project encountered three limitations when integrating with
termcat.cli that required manual workarounds. This document analyzes these
limitations and proposes extensions.

**Source**: pluckz/src/cli/cli.zig partial integration pattern

## Extension 1: Default Command

### Background

`parseApp()` originally required an explicit command name. Apps with a
"default mode" (no subcommand = run main functionality) had to handle this
manually.

**Current behavior** (Parser.zig:1044-1050):

```zig
if (i >= args.len) {
    if (@hasDecl(App, "default_command")) {
        return dispatchToCommand(..., App.default_command, &.{}, ...);
    }
    return .{ .err = CliError.usageError("missing command") };
}
```

**Historical workaround**: pluckz checked for the `auth` subcommand first, then
fell back to `Parser.parse()` for `GlobalOptions` only.

### Current usage

Add optional `default_command` declaration:

```zig
pub const MyApp = struct {
    pub const meta = .{ .name = "myapp" };
    pub const GlobalOptions = struct { verbose: bool = false };

    // Default command when no subcommand provided
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
    if (@hasDecl(App, "default_command")) {
        // Dispatch to default command with empty args
        return dispatchToCommand(..., App.default_command, &.{}, ...);
    }
    return .{ .err = CliError.usageError("missing command") };
}
```

### Alternative: Implicit Default

If no command is provided AND `GlobalOptions` has positional fields, parse those
directly:

```zig
pub const GlobalOptions = struct {
    verbose: bool = false,
    files: cli.Command.VariadicSlice = .{}, // See Extension 2

    pub const positional = .{.files};
};
```

This is more complex but matches pluckz's actual need.

---

## Extension 2: Variadic Positionals

### Background

Commands previously could only declare fixed positional arguments. Variable-
length positionals like `[files...]` required pre-filtering args before parsing.
This is now supported via `cli.Command.VariadicSlice`.

**Current behavior** (Parser.zig:280-293):

```zig
} else {
    return .{ .err = CliError.usageError("unexpected argument").withContext(arg) };
}
```

**Historical workaround**: pluckz pre-filtered file arguments into a separate
`ArrayList` before calling `Parser.parse()`.

### Current implementation: VariadicSlice (zero-copy)

Declare a variadic positional as the final positional field:

```zig
pub const Command = struct {
    output: []const u8,
    files: cli.Command.VariadicSlice = .{}, // Captures remaining positionals

    pub const positional = .{ .output, .files };

    pub const fields = .{
        .output = .{ .description = "Output file" },
        .files = .{ .description = "Input files" },
    };
};
```

Use the original args slice to materialize items:

```zig
const result = parse(Command, args);
const files = result.files.items(args);
```

The parser captures indices into the args slice (Parser.zig:363-411), so the
variadic field must be the final positional entry.

### Alternative (not implemented): trailing slice convention

If the last positional is `[][]const u8`, treat it as variadic. This remains a
possible future extension but is not implemented today.

### Allocation considerations

The current implementation is zero-copy. If an owned slice is needed, consider
adding an allocation helper (e.g., `parseAlloc`) or use a bounded array in the
command type.

---

## Extension 3: Standalone Help Utilities

### Background

Auto-generated help via `Help.zig` was originally designed for `parseApp()`
integration. Commands that used `parse()` directly had to duplicate help and
version handling.

### Current implementation

Use `parseWithHelp()` to parse a single command type and automatically print
help/version output:

```zig
const result = parseWithHelp(Options, args, writer);
switch (result) {
    .ok => |opts| runWithOptions(opts),
    .err => |err| return err,
    .handled => return, // Help/version was printed
}
```

`parseWithHelp()` uses `Help.generateHelp()` and pulls `meta.version` if
present on the command type.

### App-Level Help for Non-parseApp Usage

For apps that manually dispatch commands but want unified help output, call
`Help.generateAppHelp()` (or `cli.printAppHelp()`):

```zig
try Help.generateAppHelp(MyApp, writer);
```

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

**Current state**: `parse()` handles `--` (Parser.zig:180-197) and routes the
remaining args through the positional/variadic handling. Any future extensions
should preserve this separator behavior.

---

## VariadicSlice details (current implementation)

`cli.Command.VariadicSlice` stores indices into the original `args` slice,
avoiding allocation. Example:

```zig
pub const Command = struct {
    output: []const u8,
    files: cli.Command.VariadicSlice = .{}, // Zero-copy reference

    pub const positional = .{ .output, .files };
};
```

**Usage**:

```zig
const result = parse(Command, args);
const files = result.files.items(args); // Caller provides original args
```

**Tradeoffs**:

| Approach        | Allocation | Ergonomics    | Lifetime     |
| --------------- | ---------- | ------------- | ------------ |
| `[][]const u8`  | Yes        | Natural slice | Owned        |
| `VariadicSlice` | No         | Extra call    | Tied to args |
| `BoundedArray`  | No (stack) | Limited size  | Owned        |

**Note**: The current implementation defaults to `VariadicSlice`; an
allocation-based helper could be added in the future if needed.

---

## Help Generation (current)

### Default command display

When `default_command` is declared, `generateAppHelp()` prints both the default
mode and explicit command usage lines and annotates the default command in the
command list (Help.zig:149-172).

### Variadic positional display

Usage lines and argument lists include the `...` suffix for variadic
positionals (Help.zig:25-58).

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

1. **Owned variadic slices**: Should we add an allocation helper (e.g.,
   `parseAlloc`) or keep `VariadicSlice` as the only supported form?

2. **Help customization**: How much should generated help be customizable
   (section order, formatting)?

3. **Error context for variadics**: How to report errors in variadic args (which
   file failed to validate)?

4. **Minimum variadic count**: Should variadic positionals support a minimum
   count via metadata (e.g., a required count on positional specs)?

## Related issues

- workshop-3n72e9x - Support default commands and variadic positionals in termcat.cli.
- workshop-585hezx - Remove duplicate doc and normalize metadata for termcat CLI design notes.

## References

None.
