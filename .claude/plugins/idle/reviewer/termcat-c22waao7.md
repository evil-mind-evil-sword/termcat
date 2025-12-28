---
agent: reviewer
created: 2025-12-28T04:50:00Z
project: /Users/femtomc/Dev/termcat/.worktrees/idle/termcat-c22waao7
issue: termcat-c22waao7
status: CHANGES_REQUESTED
---

# Review: Blit/tile helpers to Plane bypass dirty tracking

## Result

**Status**: CHANGES_REQUESTED
**Summary**: Dirty rect calculation in blitBufferToPlane and blitPlaneToPlane is missing source bounds clipping step, which can mark larger regions dirty than actually modified.

## Issues

### Errors (must fix)

- `/Users/femtomc/Dev/termcat/.worktrees/idle/termcat-c22waao7/src/Blit.zig`:78-86 - `blitBufferToPlane` dirty rect calculation missing source bounds clipping. Uses `src_rect.width/height` directly instead of first clipping to source buffer bounds.

- `/Users/femtomc/Dev/termcat/.worktrees/idle/termcat-c22waao7/src/Blit.zig`:118-126 - `blitPlaneToPlane` same issue - dirty rect calculation skips source bounds clipping step.

### Warnings (should fix)

None.

### Info (suggestions)

- `/Users/femtomc/Dev/termcat/.worktrees/idle/termcat-c22waao7/src/Blit.zig`:391-407 - `tileBufferToPlane` dirty tracking looks correct, mirrors the clipping logic in `tileBufferToBuffer`.

## Claude Analysis

The fix adds `markDirtyRect` calls to three functions that previously bypassed dirty tracking. However, two of the three calculations are incorrect.

**Problem**: `blitBufferToBuffer` (the underlying copy function) uses two-step clipping:

```zig
// Step 1: Clip source region to source bounds
const src_w = @min(src_rect.width, src.width -| src_rect.x);
const src_h = @min(src_rect.height, src.height -| src_rect.y);

// Step 2: Clip to destination bounds
const copy_w = @min(src_w, dest.width -| dest_x);
const copy_h = @min(src_h, dest.height -| dest_y);
```

But the dirty tracking in `blitBufferToPlane` and `blitPlaneToPlane` only does step 2:

```zig
// MISSING step 1!
const copy_w = @min(src_rect.width, dest.width -| dest_x);
const copy_h = @min(src_rect.height, dest.height -| dest_y);
```

**Example showing the bug**:
- `src.width = 5`
- `src_region = { .x = 3, .width = 10 }` (extends past source!)
- `dest.width = 20`, `dest_x = 0`

Actual copy: `copy_w = min(min(10, 5-3), 20-0) = min(2, 20) = 2` cells
Dirty tracking: `copy_w = min(10, 20-0) = 10` cells marked dirty

This causes the dirty rect to be 5x larger than the actually modified region.

**Fix**: The dirty rect calculation should match `blitBufferToBuffer`:

```zig
// For blitBufferToPlane:
const src_rect = options.src_region orelse Rect{
    .x = 0,
    .y = 0,
    .width = src.width,
    .height = src.height,
};
// Clip to source bounds first
const src_w = @min(src_rect.width, src.width -| src_rect.x);
const src_h = @min(src_rect.height, src.height -| src_rect.y);
// Then clip to dest bounds
const copy_w = @min(src_w, dest.width -| dest_x);
const copy_h = @min(src_h, dest.height -| dest_y);

if (copy_w > 0 and copy_h > 0) {
    dest.markDirtyRect(.{
        .x = dest_x,
        .y = dest_y,
        .width = copy_w,
        .height = copy_h,
    });
}
```

## Second Opinion

The second opinion (claude -p) confirmed the analysis:

> YES. The dirty tracking in `blitBufferToPlane` is wrong. It should use the same two-step clipping:
> 1. First clip to source availability: `src_w = @min(src_rect.width, src.width -| src_rect.x)`
> 2. Then clip to dest: `copy_w = @min(src_w, dest.width -| dest_x)`
>
> Currently it skips step 1, so it can mark more cells dirty than are actually copied.

## Disputed

None - both reviewers agree on the issue.

## Verification Checklist

1. markDirtyRect is called with correct bounds for blitBufferToPlane: **NO** - missing source bounds clipping
2. markDirtyRect is called with correct bounds for blitPlaneToPlane: **NO** - missing source bounds clipping
3. markDirtyRect is called with correct bounds for tileBufferToPlane: **YES** - correct
4. The dirty rect calculation respects clipping: **PARTIAL** - tileBufferToPlane yes, others no
