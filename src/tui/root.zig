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

// Focus management (to be implemented)
// pub const Focus = @import("Focus.zig");
// pub const State = @import("State.zig");

// MVU runtime (Phase 3)
// pub const App = @import("App.zig");

// Placeholder until widget system is implemented
pub const version = "0.1.0-dev";
