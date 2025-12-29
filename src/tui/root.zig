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
const progress_mod = @import("ProgressBar.zig");
pub const ProgressBar = progress_mod.ProgressBar;
pub const ProgressBarStyle = progress_mod.BarStyle;
pub const Spinner = progress_mod.Spinner;
pub const SpinnerStyle = progress_mod.Spinner.SpinnerStyle;
const input_mod = @import("InputField.zig");
pub const InputField = input_mod.InputField;
pub const EditAction = input_mod.EditAction;
pub const Modal = @import("Modal.zig").Modal;
const tabs_mod = @import("Tabs.zig");
pub const Tabs = tabs_mod.Tabs;
pub const Tab = tabs_mod.Tab;

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

// Keybinding system (Phase 1)
const keymap_mod = @import("KeyMap.zig");
pub const KeyMap = keymap_mod.KeyMap;
pub const Binding = keymap_mod.Binding;
pub const Command = keymap_mod.Command;
pub const default_app_keymap = keymap_mod.default_app_keymap;

// Mouse hit-testing (Phase 1)
const hittest_mod = @import("HitTest.zig");
pub const HitTester = hittest_mod.HitTester;
pub const HitResult = hittest_mod.HitResult;
pub const HitOptions = hittest_mod.HitOptions;
pub const HitRect = hittest_mod.Rect;

// Event routing (Phase 1)
const eventrouter_mod = @import("EventRouter.zig");
pub const EventRouter = eventrouter_mod.EventRouter;
pub const EventHandler = eventrouter_mod.EventHandler;
pub const RouteResult = eventrouter_mod.EventResult;

// MVU runtime (Phase 3)
const app_mod = @import("App.zig");
pub const App = app_mod.App;
pub const Cmd = app_mod.Cmd;
pub const Sub = app_mod.Sub;
pub const InitResult = app_mod.InitResult;
pub const UpdateResult = app_mod.UpdateResult;

const runner_mod = @import("AppRunner.zig");
pub const AppRunnerOptions = runner_mod.Options;
pub const frameTimeMs = runner_mod.frameTimeMs;
pub const executeCmd = runner_mod.executeCmd;
pub const checkTimer = runner_mod.checkTimer;

// Placeholder until widget system is implemented
pub const version = "0.1.0-dev";
