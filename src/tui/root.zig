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

// Styled text (Phase 4)
const styled_text_mod = @import("StyledText.zig");
pub const StyledText = styled_text_mod.StyledText;
pub const OwnedStyledText = styled_text_mod.OwnedStyledText;
pub const StyledTextBuilder = styled_text_mod.StyledTextBuilder;
pub const Span = styled_text_mod.Span;

// Text truncation (Phase 4)
const truncation_mod = @import("Truncation.zig");
pub const TruncationPolicy = truncation_mod.Policy;
pub const TruncationResult = truncation_mod.Result;
pub const truncateText = truncation_mod.truncate;
pub const freeTruncationResult = truncation_mod.freeResult;
pub const applyFade = truncation_mod.applyFade;

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
const screenstack_mod = @import("ScreenStack.zig");
pub const ScreenStack = screenstack_mod.ScreenStack;
pub const Screen = screenstack_mod.Screen;
const rule_mod = @import("Rule.zig");
pub const Rule = rule_mod.Rule;
pub const RuleDirection = rule_mod.Direction;
pub const RuleLineStyle = rule_mod.LineStyle;
pub const Loading = @import("Loading.zig").Loading;
const header_mod = @import("Header.zig");
pub const Header = header_mod.Header;
pub const Footer = header_mod.Footer;
pub const KeyHint = header_mod.KeyHint;
pub const Link = @import("Link.zig").Link;
const checkbox_mod = @import("Checkbox.zig");
pub const Checkbox = checkbox_mod.Checkbox;
pub const CheckboxStyle = checkbox_mod.CheckboxStyle;
pub const RadioButton = checkbox_mod.RadioButton;
pub const Switch = checkbox_mod.Switch;
const listview_mod = @import("ListView.zig");
pub const ListView = listview_mod.ListView;
pub const ListItem = listview_mod.ListItem;
const select_mod = @import("Select.zig");
pub const Select = select_mod.Select;
pub const SelectOption = select_mod.Option;
pub const Collapsible = @import("Collapsible.zig").Collapsible;
pub const TextArea = @import("TextArea.zig").TextArea;
const log_mod = @import("Log.zig");
pub const Log = log_mod.Log;
pub const LogLevel = log_mod.LogLevel;
pub const LogEntry = log_mod.LogEntry;
const toast_mod = @import("Toast.zig");
pub const Toast = toast_mod.Toast;
pub const ToastLevel = toast_mod.ToastLevel;
pub const ToastMessage = toast_mod.ToastMessage;
const sparkline_mod = @import("Sparkline.zig");
pub const Sparkline = sparkline_mod.Sparkline;
pub const Digits = sparkline_mod.Digits;
const autocomplete_mod = @import("Autocomplete.zig");
pub const Autocomplete = autocomplete_mod.Autocomplete;
pub const Suggestion = autocomplete_mod.Suggestion;
pub const prefixFilter = autocomplete_mod.prefixFilter;
pub const prefixFilterIgnoreCase = autocomplete_mod.prefixFilterIgnoreCase;
pub const containsFilter = autocomplete_mod.containsFilter;
const tree_mod = @import("Tree.zig");
pub const Tree = tree_mod.Tree;
pub const TreeNode = tree_mod.TreeNode;
const datatable_mod = @import("DataTable.zig");
pub const DataTable = datatable_mod.DataTable;
pub const DataTableColumn = datatable_mod.Column;
pub const DataTableRow = datatable_mod.Row;
const diff_mod = @import("Diff.zig");
pub const Diff = diff_mod.Diff;
pub const DiffLine = diff_mod.DiffLine;
pub const DiffLineType = diff_mod.LineType;
pub const DiffMode = diff_mod.DiffMode;
const markdown_mod = @import("Markdown.zig");
pub const Markdown = markdown_mod.Markdown;
pub const MarkdownBlock = markdown_mod.Block;
pub const MarkdownBlockType = markdown_mod.BlockType;
pub const parseMarkdownBlockType = markdown_mod.parseBlockType;
pub const Terminal = @import("Terminal.zig").Terminal;
const cmdpalette_mod = @import("CommandPalette.zig");
pub const CommandPalette = cmdpalette_mod.CommandPalette;
pub const PaletteCommand = cmdpalette_mod.Command;
pub const fuzzyFilter = cmdpalette_mod.fuzzyFilter;
pub const palettePrefixFilter = cmdpalette_mod.prefixFilter;

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

// Testing utilities (Phase 9)
pub const Snapshot = @import("Snapshot.zig");

// Performance utilities (Phase 8)
pub const MeasureCache = @import("MeasureCache.zig");
pub const FramePacer = @import("FramePacer.zig");

// Placeholder until widget system is implemented
pub const version = "0.1.0-dev";
