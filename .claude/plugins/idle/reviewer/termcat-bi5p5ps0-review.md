---
agent: reviewer
created: 2025-12-28T00:00:00Z
project: /Users/femtomc/Dev/termcat/.worktrees/idle/termcat-bi5p5ps0
issue: termcat-bi5p5ps0
status: CHANGES_REQUESTED
---

# Code Review: blitBufferToBuffer overlap fix

## Summary

The fix adds overlap handling to `blitBufferToBuffer` with a two-tier strategy:
1. Primary: Allocate temp buffer, copy source to temp, then copy to dest
2. Fallback: When allocation fails, use reverse-order copy for forward shifts

## Issues Found

### Errors (must fix)

**1. Reverse copy handles wide characters incorrectly**
- File: `/Users/femtomc/Dev/termcat/.worktrees/idle/termcat-bi5p5ps0/src/Blit.zig`
- Lines: 192-235

When iterating in reverse order (dx from copy_w-1 down to 0), wide character handling is broken:

```
Buffer layout: [A, WideBase, Cont, B] at positions 0, 1, 2, 3
Reverse iteration order: dx=3, dx=2, dx=1, dx=0
```

- At dx=2: `cell.isContinuation()` is true, dx != 0, so we fall through. `isWideChar()` returns false for continuation cells. We copy the continuation cell to dest before copying its base.
- At dx=1: `is_wide=true`. We copy base cell to dest[1], continuation to dest[2]. Then `dx -= 1` makes dx=0.
- At dx=0: We process 'A' normally.

The issue is we copy the continuation cell twice: once at dx=2 (blindly), and again at dx=1 (intentionally as part of wide char). Also, `dx -= 1` is meant to skip the continuation, but in reverse order the continuation was already processed at a higher dx value.

**Correct approach for reverse copy with wide chars:**
- When encountering a continuation cell during reverse iteration, skip it (it will be handled when we reach the base char)
- When encountering a base wide char, copy both base and continuation, but do NOT adjust dx since the continuation is at a higher index (already processed or will be skipped)

**2. Orphan continuation detection is incomplete for reverse iteration**
- File: `/Users/femtomc/Dev/termcat/.worktrees/idle/termcat-bi5p5ps0/src/Blit.zig`
- Lines: 198-206

The orphan check only handles `dx == 0`. In reverse iteration, an orphan continuation would be at the END of the source region (highest dx), not the start. The check should be:

```zig
if (cell.isContinuation()) {
    if (dx == @as(i32, copy_w) - 1) {
        // Orphan continuation at end of region - skip
        continue;
    }
    // Otherwise skip all continuations - they'll be handled with their base
    continue;
}
```

### Warnings (should fix)

**3. Test does not actually exercise reverse copy path**
- File: `/Users/femtomc/Dev/termcat/.worktrees/idle/termcat-bi5p5ps0/src/Blit.zig`
- Lines: 1270-1311

Test "blitBufferToBuffer reverse copy fallback for wide chars" uses `std.testing.allocator` which will succeed, so temp buffer allocation succeeds and reverse copy is never exercised. Consider using a failing allocator or mocking the allocation failure.

**4. Linear index comparison uses different width variables**
- File: `/Users/femtomc/Dev/termcat/.worktrees/idle/termcat-bi5p5ps0/src/Blit.zig`
- Lines: 176-177

```zig
const src_start = @as(usize, src_y) * @as(usize, src.width) + @as(usize, src_x);
const dest_start = @as(usize, dest_y) * @as(usize, dest.width) + @as(usize, dest_x);
```

While correct (since `buffersAlias` ensures same buffer), using `src.width` vs `dest.width` is confusing. Both should use the same width variable for clarity.

### Info (suggestions)

**5. Code duplication between forward and reverse loops**
- Lines: 187-284

The forward and reverse copy loops have significant duplication. Consider extracting common cell-processing logic into a helper function.

**6. Missing edge case test: overlapping regions that don't require reverse copy**
- When dest_start <= src_start, forward copy is safe even without temp buffer, but the code still uses forward copy correctly in this case.

## Second Opinion

The second opinion model was invoked but returned inconsistent responses across iterations, possibly due to context limitations. Manual analysis was performed to verify findings.

## Recommendation

**CHANGES_REQUESTED**: The reverse copy path has correctness bugs with wide character handling that would cause data corruption when:
1. Temp buffer allocation fails (OOM scenario)
2. AND source/dest overlap with dest after src
3. AND source contains wide characters

While this is a fallback path that may rarely trigger in practice, the bugs should be fixed for correctness.
