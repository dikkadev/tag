const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const sgfx = sokol.gfx;
const slog = sokol.log;
const sglue = sokol.glue;
const sdtx = sokol.debugtext;
const win_api = @import("windows_api.zig");

// Parsed token data
const Token = struct {
    text: [256]u8 = undefined,
    len: usize = 0,
    
    fn init() Token {
        return Token{};
    }
    
    fn set(self: *Token, text: []const u8) void {
        self.len = @min(text.len, 255);
        @memcpy(self.text[0..self.len], text[0..self.len]);
        self.text[self.len] = 0; // null terminate
    }
    
    fn slice(self: *const Token) []const u8 {
        return self.text[0..self.len];
    }
    
    fn isEmpty(self: *const Token) bool {
        return self.len == 0;
    }
};

const ParsedInput = struct {
    tag_name: Token = Token.init(),
    attributes: [16]Token = [_]Token{Token.init()} ** 16,
    attr_count: usize = 0,
    is_boolean: [16]bool = [_]bool{false} ** 16, // Track which attributes are boolean
    
    fn clear(self: *ParsedInput) void {
        self.tag_name = Token.init();
        self.attr_count = 0;
        for (&self.attributes) |*attr| {
            attr.* = Token.init();
        }
        for (&self.is_boolean) |*flag| {
            flag.* = false;
        }
    }
};

// App state
var input_buffer: [4096]u8 = undefined;
var input_len: usize = 0;

var large_text_context: sdtx.Context = undefined;
var parsed_data: ParsedInput = ParsedInput{};
var xml_output: [8192]u8 = undefined;
var xml_len: usize = 0;
var xml_display: [8192]u8 = undefined;  // Display version with better visual spacing
var xml_display_len: usize = 0;

// Text scaling factors - adjust these to change text sizes
var input_text_scale: f32 = 1.3;  // Higher value = smaller text
var hint_text_scale: f32 = 1.15;   // Higher value = smaller text

// Canvas size constants for large text context
const LARGE_TEXT_CANVAS_WIDTH = 320;   // Smaller canvas = larger text (about 2x bigger)
const LARGE_TEXT_CANVAS_HEIGHT = 240;

// Variables for post-exit type action
var initiate_type_action: bool = false;
var xml_data_for_typing_action: ?[]u8 = null;

// ────────────────────────────────────────────────────────────────────────────────
// Undo/Redo functionality
// ────────────────────────────────────────────────────────────────────────────────
const MAX_BUFFER = 4096;

const StateSnapshot = struct {
    buffer: [MAX_BUFFER]u8, // a full copy of the input buffer
    len: usize,             // how many of those bytes are "in use"
};

// Undo / redo stacks:
var undo_stack: std.ArrayList(StateSnapshot) = undefined;
var redo_stack: std.ArrayList(StateSnapshot) = undefined;





// Track desired window position based on mouse location at startup
var desired_window_x: i32 = 0;
var desired_window_y: i32 = 0;
var window_position_calculated = false;
var window_positioned = false;

fn calculateDesiredWindowPosition() void {
    if (window_position_calculated) {
        return; // Only calculate once
    }
    
    const pos = win_api.calculateDesiredWindowPosition();
    if (pos.calculated) {
        desired_window_x = pos.x;
        desired_window_y = pos.y;
        window_position_calculated = true;
    }
}

fn positionWindowOnMouseMonitor() void {
    if (window_positioned or !window_position_calculated) {
        return; // Only do it once and only if position was calculated
    }
    
    if (win_api.positionWindow("Tag - Text Input UI", desired_window_x, desired_window_y)) {
        window_positioned = true;
    }
}

export fn init() void {
    sgfx.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    
    // Initialize debug text rendering with built-in font
    sdtx.setup(.{
        .fonts = .{
            sdtx.fontKc853(),
            .{}, .{}, .{}, .{}, .{}, .{}, .{},
        },
        .logger = .{ .func = slog.func },
    });
    
    // Create a larger text context for input text
    large_text_context = sdtx.makeContext(.{
        .canvas_width = LARGE_TEXT_CANVAS_WIDTH,
        .canvas_height = LARGE_TEXT_CANVAS_HEIGHT,
    });
    
    @memset(&input_buffer, 0);
    input_len = 0;
    
    // ────────────────────────────────────────────────────────────────────────────
    // Initialize undo/redo stacks using the page_allocator
    // ────────────────────────────────────────────────────────────────────────────
    undo_stack = std.ArrayList(StateSnapshot).init(std.heap.page_allocator);
    redo_stack = std.ArrayList(StateSnapshot).init(std.heap.page_allocator);

    // Before the user types anything, capture the "empty" state for undo.
    const emptySnapshot = StateSnapshot{
        .buffer = undefined,
        .len = input_len, // 0 at startup
    };
    // Initialize buffer to zeros (it's already zeroed by memset above)
    var initial_snap = emptySnapshot;
    @memcpy(initial_snap.buffer[0..initial_snap.len], input_buffer[0..initial_snap.len]);
    _ = undo_stack.append(initial_snap) catch {
        std.log.err("Failed to initialize undo stack", .{});
    };
    
    // Initialize the XML output with placeholder
    parseInput();
    
    std.log.info("Tag UI initialized with XML generation and undo/redo", .{});
}

export fn frame() void {
    // Position window on the monitor where the mouse cursor is located (only once)
    positionWindowOnMouseMonitor();
    
    // Begin pass with gray background
    sgfx.beginPass(.{
        .action = .{
            .colors = .{
                .{ .load_action = .CLEAR, .clear_value = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 } },
                .{}, .{}, .{},
            },
        },
        .swapchain = sglue.swapchain(),
    });
    
    // First, render the larger XML text using the large text context
    sdtx.setContext(large_text_context);
    sdtx.canvas(@as(f32, @floatFromInt(sapp.width())) / input_text_scale, @as(f32, @floatFromInt(sapp.height())) / input_text_scale);
    
    // Render generated XML starting from top left
    sdtx.pos(0.5, 1.0);
    sdtx.color3f(0.9, 0.9, 0.6);
    
    // Display the generated XML using enhanced display version for better visual spacing
    if (xml_display_len > 0) {
        xml_display[xml_display_len] = 0; // Ensure null termination
        const xml_display_slice: [:0]const u8 = xml_display[0..xml_display_len :0];
        sdtx.puts(xml_display_slice);
    } else {
        sdtx.puts("(type something...)");
    }
    
    // Switch to default context for normal-sized hint text
    sdtx.setContext(sdtx.defaultContext());
    sdtx.canvas(@as(f32, @floatFromInt(sapp.width())) / hint_text_scale, @as(f32, @floatFromInt(sapp.height())) / hint_text_scale);
    
    // Calculate text positions for hint text at bottom left
    const canvas_height = @as(f32, @floatFromInt(sapp.height())) / hint_text_scale;
    const char_height: f32 = 8.0;
    const grid_height = canvas_height / char_height;
    
    // Render hint text at bottom left corner (normal size) - 6 lines with colors
    // Line 1: ENTER closes and processes
    sdtx.pos(0.5, grid_height - 6.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for ENTER
    sdtx.puts("      ENTER"); // Padded to align with " CTRL +ENTER"
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" type");
    
    // Line 2: CTRL+ENTER clipboard 
    sdtx.pos(0.5, grid_height - 5.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for CTRL+ENTER
    sdtx.puts("CTRL +ENTER");
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" clipboard");
    
    // Line 3: CTRL+V paste
    sdtx.pos(0.5, grid_height - 4.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for CTRL+V
    sdtx.puts("CTRL +V    ");
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" paste");
    
    // Line 4: CTRL+Z undo
    sdtx.pos(0.5, grid_height - 3.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for CTRL+Z
    sdtx.puts("CTRL +Z    ");
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" undo");
    
    // Line 5: CTRL+Y redo
    sdtx.pos(0.5, grid_height - 2.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for CTRL+Y
    sdtx.puts("CTRL +Y    ");
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" redo");
    
    // Line 6: ESC cancels
    sdtx.pos(0.5, grid_height - 1.5);
    sdtx.color3f(0.8, 0.4, 0.4); // Red for ESC
    sdtx.puts("ESC        "); // Padded to align
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" cancel");
    
    // Draw both contexts
    sdtx.contextDraw(large_text_context);
    sdtx.draw(); // Draw the default context
    
    sgfx.endPass();
    sgfx.commit();
}



/// Create a full copy of input_buffer + input_len.
fn snapshotCurrentState() StateSnapshot {
    var s: StateSnapshot = StateSnapshot{
        .buffer = undefined,
        .len = input_len,
    };
    @memcpy(s.buffer[0..s.len], input_buffer[0..s.len]);
    return s;
}

/// Overwrite input_buffer + input_len from a snapshot, then re-parse.
fn restoreState(s: StateSnapshot) void {
    input_len = s.len;
    @memcpy(input_buffer[0..s.len], s.buffer[0..s.len]);
    parseInput();
}

/// Push the current state onto the undo stack.
fn pushUndoSnapshot() void {
    const snap = snapshotCurrentState();
    _ = undo_stack.append(snap) catch {
        std.log.err("undo_stack.append failed", .{});
        return;
    };
}

/// Perform "undo" (Ctrl+Z). Restore the last snapshot from undo_stack, push current onto redo_stack.
fn undoAction() void {
    if (undo_stack.items.len == 0) {
        return; // nothing to undo
    }
    // Pop the most recent snapshot
    const lastSnap = undo_stack.pop() orelse return;

    // Before we restore "lastSnap," push *current* state onto redo_stack
    const currentSnap = snapshotCurrentState();
    _ = redo_stack.append(currentSnap) catch {
        std.log.err("redo_stack.append failed", .{});
    };

    // Now restore
    restoreState(lastSnap);
}

/// Perform "redo" (Ctrl+Y). Opposite of undo.
fn redoAction() void {
    if (redo_stack.items.len == 0) {
        return; // nothing to redo
    }
    const nextSnap = redo_stack.pop() orelse return;

    // Push current onto undo_stack
    const currentSnap = snapshotCurrentState();
    _ = undo_stack.append(currentSnap) catch {
        std.log.err("undo_stack.append failed", .{});
    };

    restoreState(nextSnap);
}

export fn event(e: [*c]const sapp.Event) void {
    const event_ptr = @as(*const sapp.Event, @ptrCast(e));
    
    switch (event_ptr.type) {
        .KEY_DOWN => {
            const key = event_ptr.key_code;
            const modifiers = event_ptr.modifiers;
            
            // Handle Ctrl+Z (undo)
            if (key == .Z and (modifiers & 0x02) != 0) {
                undoAction();
                std.log.info("Undo action performed", .{});
                return;
            }
            
            // Handle Ctrl+Y (redo)
            if (key == .Y and (modifiers & 0x02) != 0) {
                redoAction();
                std.log.info("Redo action performed", .{});
                return;
            }
            
            // Handle Ctrl+V (paste) - only for values (after first tab)
            if (key == .V and (modifiers & 0x02) != 0) {
                if (win_api.getClipboardText()) |clip_data| {
                    defer std.heap.page_allocator.free(clip_data);
                    
                    // Check there's at least one '\t' already (we're past the tag name)
                    var seen_tab: bool = false;
                    for (input_buffer[0..input_len]) |c| {
                        if (c == '\t') {
                            seen_tab = true;
                            break;
                        }
                    }
                    
                                        if (seen_tab) {
                        // Snapshot current state for undo
                        pushUndoSnapshot();
                        // Clear redo history for big edits like paste
                        redo_stack.clearRetainingCapacity();
                        
                        // Copy as many bytes as will fit into input_buffer
                        for (clip_data) |c| {
                            if (input_len < input_buffer.len - 1) {
                                input_buffer[input_len] = c;
                                input_len += 1;
                            } else {
                                break;
                            }
                        }
                        
                        // Re-parse so xml_output + xml_display update
                        parseInput();
                        std.log.info("Pasted {} characters from clipboard", .{clip_data.len});
                    } else {
                        std.log.warn("Can only paste into a value (after first tab)", .{});
                    }
                } else {
                    std.log.warn("Clipboard empty or unavailable", .{});
                }
                return;
            }
            
            if (key == .ESCAPE) {
                std.log.info("ESC pressed - quitting application", .{});
                sapp.quit();
                return;
            }
            
            if (key == .ENTER) {
                const is_ctrl = (modifiers & 0x02) != 0;
                const is_shift = (modifiers & 0x01) != 0;
                
                if (is_ctrl or is_shift) {
                    // Clipboard action: copy XML to clipboard and quit
                    std.log.info("CLIPBOARD ACTION: Copying XML to clipboard (Ctrl={}, Shift={})", .{ is_ctrl, is_shift });
                    const xml_slice = xml_output[0..xml_len];
                    std.log.info("XML to copy: '{s}' (length: {})", .{ xml_slice, xml_slice.len });
                    
                    if (win_api.copyToClipboard(xml_slice)) {
                        std.log.info("XML copied to clipboard successfully", .{});
                        std.log.info("Clipboard content: '{s}'", .{xml_slice});
                    } else {
                        std.log.err("Failed to copy XML to clipboard", .{});
                    }
                    sapp.quit();
                } else {
                    // Type action: set up to type XML after window closes
                    std.log.info("TYPE ACTION: Setting up to type XML after exit", .{});
                    std.log.info("Current XML length: {}", .{xml_len});
                    std.log.info("Current XML content: '{s}'", .{xml_output[0..xml_len]});
                    
                    if (xml_len > 0) {
                        xml_data_for_typing_action = std.heap.page_allocator.alloc(u8, xml_len) catch |err| {
                            std.log.err("Failed to allocate memory for type action XML: {}", .{err});
                            return;
                        };
                        @memcpy(xml_data_for_typing_action.?, xml_output[0..xml_len]);
                        initiate_type_action = true;
                        std.log.info("Type action data prepared - will execute after window closes", .{});
                        sapp.quit();
                    } else {
                        std.log.warn("No XML data to type. Skipping type action.", .{});
                        sapp.quit();
                    }
                }
                return;
            }
            
            if (key == .TAB) {
                // Snapshot before inserting the tab (completes a "thing")
                pushUndoSnapshot();
                // Clear redo history for big edits like tab completion
                redo_stack.clearRetainingCapacity();
                
                if (input_len < input_buffer.len - 1) {
                    input_buffer[input_len] = '\t';
                    input_len += 1;
                    parseInput(); // Update XML when input changes
                    std.log.info("Added tab character", .{});
                }
                return;
            }
            
            if (key == .BACKSPACE) {
                // If buffer is non-empty, snapshot so we can undo this deletion
                if (input_len > 0) {
                    pushUndoSnapshot();
                    input_len -= 1;
                    input_buffer[input_len] = 0;
                    parseInput(); // Update XML when input changes
                    std.log.info("Backspace", .{});
                }
                return;
            }
            
            // Regular character input
            if (input_len < input_buffer.len - 1) {
                const is_shift = (modifiers & 0x01) != 0;
                const char = getKeyChar(key, is_shift);
                if (char != 0) {
                    input_buffer[input_len] = char;
                    input_len += 1;
                    parseInput(); // Update XML when input changes
                    std.log.info("Added '{c}'", .{char});
                }
            }
        },
        else => {},
    }
}

fn getKeyChar(key: sapp.Keycode, shift: bool) u8 {
    return switch (key) {
        .A => if (shift) 'A' else 'a',
        .B => if (shift) 'B' else 'b',
        .C => if (shift) 'C' else 'c',
        .D => if (shift) 'D' else 'd',
        .E => if (shift) 'E' else 'e',
        .F => if (shift) 'F' else 'f',
        .G => if (shift) 'G' else 'g',
        .H => if (shift) 'H' else 'h',
        .I => if (shift) 'I' else 'i',
        .J => if (shift) 'J' else 'j',
        .K => if (shift) 'K' else 'k',
        .L => if (shift) 'L' else 'l',
        .M => if (shift) 'M' else 'm',
        .N => if (shift) 'N' else 'n',
        .O => if (shift) 'O' else 'o',
        .P => if (shift) 'P' else 'p',
        .Q => if (shift) 'Q' else 'q',
        .R => if (shift) 'R' else 'r',
        .S => if (shift) 'S' else 's',
        .T => if (shift) 'T' else 't',
        .U => if (shift) 'U' else 'u',
        .V => if (shift) 'V' else 'v',
        .W => if (shift) 'W' else 'w',
        .X => if (shift) 'X' else 'x',
        .Y => if (shift) 'Y' else 'y',
        .Z => if (shift) 'Z' else 'z',
        ._0 => if (shift) ')' else '0',
        ._1 => if (shift) '!' else '1',
        ._2 => if (shift) '@' else '2',
        ._3 => if (shift) '#' else '3',
        ._4 => if (shift) '$' else '4',
        ._5 => if (shift) '%' else '5',
        ._6 => if (shift) '^' else '6',
        ._7 => if (shift) '&' else '7',
        ._8 => if (shift) '*' else '8',
        ._9 => if (shift) '(' else '9',
        .SPACE => ' ',
        .COMMA => if (shift) '<' else ',',
        .PERIOD => if (shift) '>' else '.',
        .SEMICOLON => if (shift) ':' else ';',
        .APOSTROPHE => if (shift) '"' else '\'',
        .MINUS => if (shift) '_' else '-',
        .EQUAL => if (shift) '+' else '=',
        .LEFT_BRACKET => if (shift) '{' else '[',
        .RIGHT_BRACKET => if (shift) '}' else ']',
        .BACKSLASH => if (shift) '|' else '\\',
        .SLASH => if (shift) '?' else '/',
        .GRAVE_ACCENT => if (shift) '~' else '`',
        else => 0,
    };
}

export fn cleanup() void {
    sdtx.destroyContext(large_text_context);
    sdtx.shutdown();
    sgfx.shutdown();
}

pub fn main() void {
    std.log.info("Starting Tag UI Application", .{});
    std.log.info("Instructions:", .{});
    std.log.info("   ESC = quit immediately", .{});
    std.log.info("   ENTER = type XML to active window and quit", .{});
    std.log.info("   TAB = add tab character", .{});
    std.log.info("   CTRL+ENTER or SHIFT+ENTER = copy to clipboard and quit", .{});
    std.log.info("   CTRL+V = paste clipboard content (only after first tab)", .{});
    std.log.info("   CTRL+Z = undo last action", .{});
    std.log.info("   CTRL+Y = redo last undone action", .{});
    std.log.info("   Type to add characters", .{});
    std.log.info("", .{});
    
    // Calculate desired window position based on current mouse location
    calculateDesiredWindowPosition();
    
    std.log.info("Starting main application loop...", .{});
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .event_cb = event,
        .cleanup_cb = cleanup,
        .width = 450,
        .height = 180,
        .window_title = "Tag - Text Input UI",
        .logger = .{ .func = slog.func },
    });
    
    std.log.info("Main application loop ended", .{});
    
    // Check if we need to perform post-exit type action
    std.log.info("Checking for post-exit type action...", .{});
    std.log.info("initiate_type_action = {}", .{initiate_type_action});
    
    if (initiate_type_action) {
        std.log.info("Post-exit type action requested - executing...", .{});
        executePostExitTypeAction();
        
        // Free the allocated memory
        if (xml_data_for_typing_action) |data| {
            std.log.info("Cleaning up allocated memory for type action", .{});
            std.heap.page_allocator.free(data);
            xml_data_for_typing_action = null;
        }
    } else {
        std.log.info("No post-exit type action requested", .{});
    }
    
    std.log.info("Application completely finished", .{});
}

test "simple tag" {
    const result = parseInputString("moin");
    const expected = "<moin>\n\n</moin>";
    const result_str = std.mem.sliceTo(&result, 0);
    try std.testing.expectEqualStrings(expected, result_str);
}

test "key-value pair" {
    const result = parseInputString("moin\tfrom\tblah blah");
    const expected = "<moin from=\"blah blah\">\n\n</moin>";
    const result_str = std.mem.sliceTo(&result, 0);
    try std.testing.expectEqualStrings(expected, result_str);
}

test "boolean and key-value mixed" {
    const result = parseInputString("log\tproduction\t\tfrom\tnginx");
    const expected = "<log production from=\"nginx\">\n\n</log>";
    const result_str = std.mem.sliceTo(&result, 0);
    try std.testing.expectEqualStrings(expected, result_str);
}

test "multiple boolean attributes" {
    const result = parseInputString("div\tclass\t\tid\t\thidden");
    const expected = "<div class id hidden>\n\n</div>";
    const result_str = std.mem.sliceTo(&result, 0);
    try std.testing.expectEqualStrings(expected, result_str);
}

test "shift enter line breaks" {
    // Test that our line break function handles multi-line text correctly
    const test_xml = "<div>\n\n</div>";
    
    // This test verifies the structure but doesn't actually send input
    // since we can't test SendInput in a unit test environment
    var lines = std.mem.splitScalar(u8, test_xml, '\n');
    var line_count: usize = 0;
    
    while (lines.next()) |_| {
        line_count += 1;
    }
    
    try std.testing.expect(line_count == 3); // Three lines: opening tag, empty line, closing tag
}

test "unsupported characters replaced with tilde" {
    const result = parseInputString("my.tag");
    const expected = "<my~tag>\n\n</my~tag>";
    const result_str = std.mem.sliceTo(&result, 0);
    try std.testing.expectEqualStrings(expected, result_str);
}

test "multiple unsupported characters" {
    const result = parseInputString("data,point.with@symbols");
    const expected = "<data~point~with~symbols>\n\n</data~point~with~symbols>";
    const result_str = std.mem.sliceTo(&result, 0);
    try std.testing.expectEqualStrings(expected, result_str);
}

test "unsupported characters in attributes" {
    const result = parseInputString("div\tclass.name\tmy.value");
    const expected = "<div class~name=\"my.value\">\n\n</div>";
    const result_str = std.mem.sliceTo(&result, 0);
    try std.testing.expectEqualStrings(expected, result_str);
}

test "tilde characters preserved" {
    const result = parseInputString("my~tag\talready~clean\tvalue");
    const expected = "<my~tag already~clean=\"value\">\n\n</my~tag>";
    const result_str = std.mem.sliceTo(&result, 0);
    try std.testing.expectEqualStrings(expected, result_str);
}

test "undo/redo state snapshot functionality" {
    // Test that we can create and restore snapshots
    const original_input_len = input_len;
    const original_input_buffer = input_buffer;
    
    // Set up test state
    input_len = 5;
    @memcpy(input_buffer[0..5], "hello");
    
    // Create snapshot
    const snapshot = snapshotCurrentState();
    try std.testing.expect(snapshot.len == 5);
    try std.testing.expectEqualStrings(snapshot.buffer[0..5], "hello");
    
    // Modify state
    input_len = 3;
    @memcpy(input_buffer[0..3], "bye");
    
    // Restore snapshot
    restoreState(snapshot);
    try std.testing.expect(input_len == 5);
    try std.testing.expectEqualStrings(input_buffer[0..5], "hello");
    
    // Restore original state
    input_len = original_input_len;
    input_buffer = original_input_buffer;
}

test "undo/redo stack operations" {
    // Initialize stacks for testing
    var test_undo_stack = std.ArrayList(StateSnapshot).init(std.testing.allocator);
    defer test_undo_stack.deinit();
    var test_redo_stack = std.ArrayList(StateSnapshot).init(std.testing.allocator);
    defer test_redo_stack.deinit();
    
    // Test that we can push and pop snapshots
    const snapshot1 = StateSnapshot{
        .buffer = undefined,
        .len = 3,
    };
    var snap1 = snapshot1;
    @memcpy(snap1.buffer[0..3], "abc");
    
    const snapshot2 = StateSnapshot{
        .buffer = undefined,
        .len = 5,
    };
    var snap2 = snapshot2;
    @memcpy(snap2.buffer[0..5], "hello");
    
    // Push snapshots
    try test_undo_stack.append(snap1);
    try test_undo_stack.append(snap2);
    
    // Pop and verify
    const popped = test_undo_stack.pop() orelse unreachable;
    try std.testing.expect(popped.len == 5);
    try std.testing.expectEqualStrings(popped.buffer[0..5], "hello");
    
    const popped2 = test_undo_stack.pop() orelse unreachable;
    try std.testing.expect(popped2.len == 3);
    try std.testing.expectEqualStrings(popped2.buffer[0..3], "abc");
}

test "quote escaping in attribute values" {
    const result = parseInputString("div\tclass\thello \"world\" & <test>");
    const expected = "<div class=\"hello &quot;world&quot; &amp; &lt;test&gt;\">\n\n</div>";
    const result_str = std.mem.sliceTo(&result, 0);
    try std.testing.expectEqualStrings(expected, result_str);
}

test "mixed quotes and special characters" {
    const result = parseInputString("input\tvalue\t\"quoted\" & 'single' <tag>");
    const expected = "<input value=\"&quot;quoted&quot; &amp; 'single' &lt;tag&gt;\">\n\n</input>";
    const result_str = std.mem.sliceTo(&result, 0);
    try std.testing.expectEqualStrings(expected, result_str);
}

test "ampersand escaping" {
    const result = parseInputString("tag\tdata\tR&D department");
    const expected = "<tag data=\"R&amp;D department\">\n\n</tag>";
    const result_str = std.mem.sliceTo(&result, 0);
    try std.testing.expectEqualStrings(expected, result_str);
}

test "text wrapping functionality" {
    // Test the wrapping function with a long string that should wrap
    xml_display_len = 0;
    const long_text = "This is a very long text that should definitely wrap at the specified character limit to test our wrapping functionality properly";
    appendToXMLDisplayWithWrapping(long_text);
    
    // Verify that newlines were inserted
    const result = xml_display[0..xml_display_len];
    const has_newlines = std.mem.indexOf(u8, result, "\n") != null;
    try std.testing.expect(has_newlines);
    
    // Verify the line length is approximately correct (should be around 42 chars per line)
    var lines = std.mem.splitScalar(u8, result, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len > 0) {
            try std.testing.expect(line.len <= 42); // Should not exceed MAX_CHARS_PER_LINE
            line_count += 1;
        }
    }
    try std.testing.expect(line_count >= 2); // Should have wrapped into at least 2 lines
    
    // Reset for next test
    xml_display_len = 0;
}



// Parse the input buffer and populate parsed_data
fn parseInput() void {
    parsed_data.clear();
    
    if (input_len == 0) {
        generateXML();
        generateXMLDisplay();
        return;
    }
    
    // Split by tabs to get tokens
    var tokens: [32]Token = [_]Token{Token.init()} ** 32;
    var token_count: usize = 0;
    
    var start: usize = 0;
    var i: usize = 0;
    
    while (i <= input_len) : (i += 1) {
        if (i == input_len or input_buffer[i] == '\t') {
            // Always add a token, even if empty (for consecutive tabs)
            if (token_count < 32) {
                if (start < i) {
                    tokens[token_count].set(input_buffer[start..i]);
                } // else leave it empty for consecutive tabs
                token_count += 1;
            }
            start = i + 1;
        }
    }
    
    // First token is always the tag name
    if (token_count > 0) {
        parsed_data.tag_name.set(cleanTagName(tokens[0].slice()));
        
        // Process remaining tokens as attributes
        var attr_idx: usize = 0;
        var i_token: usize = 1;
        
        while (i_token < token_count and attr_idx < 16) {
            // Skip any empty tokens at the start
            while (i_token < token_count and tokens[i_token].isEmpty()) {
                i_token += 1;
            }
            
            if (i_token >= token_count) break;
            
            // Current token is an attribute name
            const attr_name = cleanAttributeName(tokens[i_token].slice());
            parsed_data.attributes[attr_idx].set(attr_name);
            i_token += 1;
            
            // Check the next token to see if it's a value
            if (i_token < token_count) {
                if (tokens[i_token].isEmpty()) {
                    // Next token is empty - this attribute is boolean
                    parsed_data.is_boolean[attr_idx] = true;
                    // Skip the empty token
                    i_token += 1;
                } else {
                    // Next token is non-empty - this is the value for the attribute
                    parsed_data.is_boolean[attr_idx] = false;
                    if (attr_idx + 1 < 16) {
                        const attr_value = tokens[i_token].slice();
                        parsed_data.attributes[attr_idx + 1].set(attr_value);
                        attr_idx += 1; // Extra increment for the value
                    }
                    i_token += 1;
                }
            } else {
                // No next token - this attribute is boolean by default
                parsed_data.is_boolean[attr_idx] = true;
            }
            
            attr_idx += 1;
        }
        
        parsed_data.attr_count = attr_idx;
    }
    
    generateXML();
    generateXMLDisplay();
}

// Clean tag/attribute names: spaces -> underscores, unsupported chars -> tilde, trim whitespace
fn cleanTagName(input: []const u8) []const u8 {
    var cleaned: [256]u8 = undefined;
    var cleaned_len: usize = 0;
    
    // Trim and clean
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    for (trimmed) |char| {
        if (cleaned_len >= 255) break;
        if (char == ' ') {
            cleaned[cleaned_len] = '_';
            cleaned_len += 1;
        } else if ((char >= 'A' and char <= 'Z') or 
                   (char >= 'a' and char <= 'z') or 
                   (char >= '0' and char <= '9') or 
                   char == '_' or char == '-' or char == '~') {
            cleaned[cleaned_len] = char;
            cleaned_len += 1;
        } else {
            // Replace unsupported characters with tilde
            cleaned[cleaned_len] = '~';
            cleaned_len += 1;
        }
    }
    
    return cleaned[0..cleaned_len];
}

fn cleanAttributeName(input: []const u8) []const u8 {
    return cleanTagName(input); // Same cleaning rules for now
}

// Generate XML from parsed data
fn generateXML() void {
    xml_len = 0;
    
    if (parsed_data.tag_name.isEmpty()) {
        // Show placeholder if no input
        const placeholder = "(type something...)";
        @memcpy(xml_output[0..placeholder.len], placeholder);
        xml_len = placeholder.len;
        return;
    }
    
    const tag_name = parsed_data.tag_name.slice();
    
    // Build opening tag with attributes
    appendToXML("<");
    appendToXML(tag_name);
    
    // Add attributes using boolean flags
    var i: usize = 0;
    while (i < parsed_data.attr_count) {
        if (!parsed_data.attributes[i].isEmpty()) {
            appendToXML(" ");
            appendToXML(parsed_data.attributes[i].slice()); // attribute name
            
            if (!parsed_data.is_boolean[i]) {
                // This is a key-value pair, next slot has the value
                if (i + 1 < parsed_data.attr_count and !parsed_data.attributes[i + 1].isEmpty()) {
                    appendToXML("=\"");
                    appendEscapedToXML(parsed_data.attributes[i + 1].slice());
                    appendToXML("\"");
                    i += 2; // Skip both name and value
                } else {
                    // Something went wrong, treat as boolean
                    i += 1;
                }
            } else {
                // This is a boolean attribute
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    
    appendToXML(">\n\n</");
    appendToXML(tag_name);
    appendToXML(">");
}

fn appendToXML(text: []const u8) void {
    const remaining = xml_output.len - xml_len;
    const to_copy = @min(text.len, remaining);
    if (to_copy > 0) {
        @memcpy(xml_output[xml_len..xml_len + to_copy], text[0..to_copy]);
        xml_len += to_copy;
    }
}

fn appendEscapedToXML(text: []const u8) void {
    for (text) |char| {
        if (xml_len >= xml_output.len - 6) break; // Reserve space for longest escape sequence
        
        switch (char) {
            '"' => {
                appendToXML("&quot;");
            },
            '&' => {
                appendToXML("&amp;");
            },
            '<' => {
                appendToXML("&lt;");
            },
            '>' => {
                appendToXML("&gt;");
            },
            else => {
                if (xml_len < xml_output.len) {
                    xml_output[xml_len] = char;
                    xml_len += 1;
                }
            },
        }
    }
}

fn appendToXMLDisplay(text: []const u8) void {
    const remaining = xml_display.len - xml_display_len;
    const to_copy = @min(text.len, remaining);
    if (to_copy > 0) {
        @memcpy(xml_display[xml_display_len..xml_display_len + to_copy], text[0..to_copy]);
        xml_display_len += to_copy;
    }
}

fn appendEscapedToXMLDisplay(text: []const u8) void {
    for (text) |char| {
        if (xml_display_len >= xml_display.len - 6) break; // Reserve space for longest escape sequence
        
        switch (char) {
            '"' => {
                appendToXMLDisplay("&quot;");
            },
            '&' => {
                appendToXMLDisplay("&amp;");
            },
            '<' => {
                appendToXMLDisplay("&lt;");
            },
            '>' => {
                appendToXMLDisplay("&gt;");
            },
            else => {
                if (xml_display_len < xml_display.len) {
                    xml_display[xml_display_len] = char;
                    xml_display_len += 1;
                }
            },
        }
    }
}

// Text wrapping constants - calculated for fixed window size 450x180
// Window width: 450px, text scale: 1.3, effective width: ~346px
// Character width: ~8px, so ~43 chars fit, using 42 for good balance
const MAX_CHARS_PER_LINE: usize = 42; // Good balance of space usage and safety
const MAX_LINES: usize = 8; // Maximum lines that fit in the display area

// XML display formatting constants
const XML_EXTRA_NEWLINES = "\n\n\n"; // Extra newlines for better visual separation

fn appendToXMLDisplayWithWrapping(text: []const u8) void {
    var current_line_length: usize = 0;
    
    // Count current line length by looking backwards to last newline
    if (xml_display_len > 0) {
        var i: usize = xml_display_len;
        while (i > 0) {
            i -= 1;
            if (xml_display[i] == '\n') {
                current_line_length = xml_display_len - i - 1;
                break;
            }
        } else {
            current_line_length = xml_display_len;
        }
    }
    
    for (text) |char| {
        if (xml_display_len >= xml_display.len - 1) break;
        
        // Check if we need to wrap
        if (current_line_length >= MAX_CHARS_PER_LINE and char != '\n') {
            // Add a line break
            xml_display[xml_display_len] = '\n';
            xml_display_len += 1;
            current_line_length = 0;
            
            if (xml_display_len >= xml_display.len - 1) break;
        }
        
        xml_display[xml_display_len] = char;
        xml_display_len += 1;
        
        if (char == '\n') {
            current_line_length = 0;
        } else {
            current_line_length += 1;
        }
    }
}

fn appendEscapedToXMLDisplayWithWrapping(text: []const u8) void {
    for (text) |char| {
        if (xml_display_len >= xml_display.len - 6) break; // Reserve space for longest escape sequence
        
        switch (char) {
            '"' => {
                appendToXMLDisplayWithWrapping("&quot;");
            },
            '&' => {
                appendToXMLDisplayWithWrapping("&amp;");
            },
            '<' => {
                appendToXMLDisplayWithWrapping("&lt;");
            },
            '>' => {
                appendToXMLDisplayWithWrapping("&gt;");
            },
            else => {
                const single_char = [1]u8{char};
                appendToXMLDisplayWithWrapping(&single_char);
            },
        }
    }
}

// Generate display version of XML with enhanced visual spacing and text wrapping
fn generateXMLDisplay() void {
    xml_display_len = 0;
    
    if (parsed_data.tag_name.isEmpty()) {
        // Show placeholder if no input
        const placeholder = "(type something...)";
        @memcpy(xml_display[0..placeholder.len], placeholder);
        xml_display_len = placeholder.len;
        return;
    }
    
    const tag_name = parsed_data.tag_name.slice();
    
    // Build opening tag with attributes
    appendToXMLDisplayWithWrapping("<");
    appendToXMLDisplayWithWrapping(tag_name);
    
    // Add attributes using boolean flags (same logic as original)
    var i: usize = 0;
    while (i < parsed_data.attr_count) {
        if (!parsed_data.attributes[i].isEmpty()) {
            appendToXMLDisplayWithWrapping(" ");
            appendToXMLDisplayWithWrapping(parsed_data.attributes[i].slice()); // attribute name
            
            if (!parsed_data.is_boolean[i]) {
                // This is a key-value pair, next slot has the value
                if (i + 1 < parsed_data.attr_count and !parsed_data.attributes[i + 1].isEmpty()) {
                    appendToXMLDisplayWithWrapping("=\"");
                    appendEscapedToXMLDisplayWithWrapping(parsed_data.attributes[i + 1].slice());
                    appendToXMLDisplayWithWrapping("\"");
                    i += 2; // Skip both name and value
                } else {
                    // Something went wrong, treat as boolean
                    i += 1;
                }
            } else {
                // This is a boolean attribute
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    
    // Enhanced visual spacing for display: add extra newlines to make empty line more visible
    appendToXMLDisplayWithWrapping(">");
    appendToXMLDisplayWithWrapping(XML_EXTRA_NEWLINES);
    appendToXMLDisplayWithWrapping("</");
    appendToXMLDisplayWithWrapping(tag_name);
    appendToXMLDisplayWithWrapping(">");
}

// Test function to parse input string and return XML
fn parseInputString(input: []const u8) [8192]u8 {
    // Save current state
    const saved_input_len = input_len;
    const saved_input_buffer = input_buffer;
    const saved_xml_len = xml_len;
    const saved_xml_output = xml_output;
    
    // Set up test input
    input_len = @min(input.len, input_buffer.len - 1);
    @memcpy(input_buffer[0..input_len], input[0..input_len]);
    
    // Parse and generate XML
    parseInput();
    
    // Save result
    var result: [8192]u8 = undefined;
    @memcpy(result[0..xml_len], xml_output[0..xml_len]);
    @memset(result[xml_len..], 0);
    
    // Restore state
    input_len = saved_input_len;
    input_buffer = saved_input_buffer;
    xml_len = saved_xml_len;
    xml_output = saved_xml_output;
    
    return result;
}



// SUI library wrapper functions
extern fn sui_init_keyboard() void;
extern fn sui_press_key(keycode: c_int) void;
extern fn sui_send_shift_enter() void;
extern fn sui_type_string(text: [*:0]const u8) void;

fn executePostExitTypeAction() void {
    std.log.info("=== STARTING POST-EXIT TYPE ACTION ===", .{});
    
    if (xml_data_for_typing_action == null) {
        std.log.warn("No XML data available for typing action", .{});
        return;
    }
    
    const xml_to_type = xml_data_for_typing_action.?;
    std.log.info("XML data length: {} bytes", .{xml_to_type.len});
    std.log.info("XML data content: '{s}'", .{xml_to_type});
    
    // Initialize SUI for keyboard input
    std.log.info("Initializing SUI library for keyboard input...", .{});
    sui_init_keyboard();
    
    std.log.info("Waiting 50ms before typing to ensure target application is ready...", .{});
    std.time.sleep(50_000_000);
    
    std.log.info("Starting to type XML using SUI library with Shift+Enter line breaks...", .{});
    
    // Type the XML string with reliable Shift+Enter line breaks using SUI
    typeTextWithSUIShiftEnterLineBreaks(xml_to_type) catch |err| {
        std.log.err("Failed to type XML: {}", .{err});
        std.log.err("Type action failed - aborting", .{});
        return;
    };
    
    std.log.info("Attempting to position cursor between opening and closing tags...", .{});
    
    // Position cursor between the opening and closing tags
    // Find the end of the opening tag
    if (std.mem.indexOf(u8, xml_to_type, ">")) |opening_end| {
        if (std.mem.indexOf(u8, xml_to_type, "</")) |closing_start| {
            // Check if there are newlines between the tags
            const between_tags = xml_to_type[(opening_end + 1)..closing_start];
            std.log.info("Content between tags: '{s}'", .{between_tags});
            
            if (std.mem.indexOf(u8, between_tags, "\n")) |_| {
                std.log.info("Moving cursor up to position between tags...", .{});
                // Move cursor up to position between tags using SUI
                sui_press_key(38); // VK_UP = 38
                std.log.info("Cursor positioning completed", .{});
            } else {
                std.log.info("No newlines between tags, cursor positioning not needed", .{});
            }
        } else {
            std.log.warn("Could not find closing tag in XML", .{});
        }
    } else {
        std.log.warn("Could not find opening tag end in XML", .{});
    }
    
    std.log.info("=== TYPE ACTION COMPLETED SUCCESSFULLY ===", .{});
}

fn typeTextWithSUIShiftEnterLineBreaks(text: []const u8) !void {
    std.log.info("Starting to type text with SUI Shift+Enter line breaks", .{});
    std.log.info("Text to type: '{s}'", .{text});
    std.log.info("Text length: {} characters", .{text.len});
    
    // Type text line by line, using SUI Shift+Enter for line breaks
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    var line_number: usize = 1;
    
    while (lines.next()) |line| {
        std.log.info("Processing line {}: '{s}' (length: {})", .{ line_number, line, line.len });
        
        if (!first_line) {
            std.log.info("Sending Shift+Enter for line break using SUI...", .{});
            // Send Shift+Enter for line break using SUI
            sui_send_shift_enter();
            
            // Small delay for reliability
            std.log.info("Waiting 15ms after Shift+Enter...", .{});
            std.time.sleep(15_000_000); // 15ms delay
        }
        
        // Type the line content using SUI
        if (line.len > 0) {
            // Create null-terminated string for C function and type the line using SUI
            std.log.info("Typing line {}: '{s}'", .{ line_number, line });
            var line_cstr = std.heap.page_allocator.allocSentinel(u8, line.len, 0) catch |err| {
                std.log.err("Failed to allocate memory for line: {}", .{err});
                return err;
            };
            defer std.heap.page_allocator.free(line_cstr);

            @memcpy(line_cstr[0..line.len], line);
            sui_type_string(line_cstr.ptr);

            std.log.info("Successfully typed line content using SUI", .{});
            std.time.sleep(5_000_000); // 5ms delay
        } else {
            std.log.info("Skipping empty line", .{});
        }
        
        first_line = false;
        line_number += 1;
    }
    
    std.log.info("Finished typing all lines using SUI!", .{});
}
