//! termcat.tui - TUI framework layer
//!
//! Higher-level abstractions for building terminal user interfaces:
//! - Widget system with two-phase layout
//! - Theming and styling
//! - Focus management
//! - Optional MVU application runtime

// Rendering abstractions (Phase 0)
pub const PlaneView = @import("PlaneView.zig").PlaneView;

// Widget system (Phase 1)
const widget_mod = @import("Widget.zig");
pub const Widget = widget_mod.Widget;
pub const VTable = widget_mod.VTable;
pub const SizeConstraint = widget_mod.SizeConstraint;
pub const MeasuredSize = widget_mod.MeasuredSize;
pub const WidgetState = widget_mod.WidgetState;
pub const EventResult = widget_mod.EventResult;
pub const isWidget = widget_mod.isWidget;

const theme_mod = @import("Theme.zig");
pub const Theme = theme_mod.Theme;
pub const Style = theme_mod.Style;

// Widget identity (Phase 1)
const id_mod = @import("Id.zig");
pub const Id = id_mod.Id;
pub const IdStack = id_mod.IdStack;

// State management (Phase 1)
pub const StateStore = @import("State.zig").StateStore;

// Layout constraints (Phase 1)
const constraint_mod = @import("Constraint.zig");
pub const Constraint = constraint_mod.Constraint;
pub const resolveConstraints = constraint_mod.resolve;
pub const resolveConstraintsWithAllocator = constraint_mod.resolveWithAllocator;
pub const freeConstraintSizes = constraint_mod.freeSizes;

// Basic widgets (Phase 2)
pub const Label = @import("Label.zig").Label;
pub const Button = @import("Button.zig").Button;

// Decorator widgets (Phase 2)
const padding_mod = @import("Padding.zig");
pub const Padding = padding_mod.Padding;
pub const Insets = padding_mod.Insets;
const border_mod = @import("Border.zig");
pub const Border = border_mod.Border;
pub const BoxStyle = border_mod.BoxStyle;

// Container widgets (Phase 2)
const flex_mod = @import("Flex.zig");
pub const Flex = flex_mod.Flex;
pub const FlexDirection = flex_mod.Direction;
pub const FlexChild = flex_mod.FlexChild;
pub const ScrollView = @import("ScrollView.zig").ScrollView;

// Focus management (Phase 4)
pub const FocusManager = @import("FocusManager.zig").FocusManager;

// MVU runtime (Phase 3)
// pub const App = @import("App.zig");

// Placeholder until widget system is implemented
pub const version = "0.1.0-dev";
