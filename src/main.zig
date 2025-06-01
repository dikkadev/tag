const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const sgfx = sokol.gfx;
const slog = sokol.log;
const sglue = sokol.glue;
const sdtx = sokol.debugtext;
const win_api = @import("windows_api.zig");
const xml_gen = @import("xml_generator.zig");
const undo_redo = @import("undo_redo.zig");



// App state
var input_buffer: [4096]u8 = undefined;
var input_len: usize = 0;

var large_text_context: sdtx.Context = undefined;
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

// Undo/redo system instance
var undo_redo_system: undo_redo.UndoRedoSystem = undefined;





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
    // Initialize undo/redo system
    // ────────────────────────────────────────────────────────────────────────────
    undo_redo_system = undo_redo.UndoRedoSystem.init();

    // Before the user types anything, capture the "empty" state for undo.
    const initial_state = input_buffer[0..input_len];
    undo_redo_system.pushSnapshot(initial_state);
    
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
    
    // Render hint text at bottom left corner (normal size) - 7 lines with colors
    // Line 1: ENTER closes and processes
    sdtx.pos(0.5, grid_height - 7.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for ENTER
    sdtx.puts("      ENTER"); // Padded to align with " CTRL +ENTER"
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" type");
    
    // Line 2: CTRL+ENTER clipboard 
    sdtx.pos(0.5, grid_height - 6.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for CTRL+ENTER
    sdtx.puts("CTRL +ENTER");
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" clipboard");
    
    // Line 3: CTRL+V paste
    sdtx.pos(0.5, grid_height - 5.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for CTRL+V
    sdtx.puts("CTRL +V    ");
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" paste");
    
    // Line 4: CTRL+Z undo
    sdtx.pos(0.5, grid_height - 4.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for CTRL+Z
    sdtx.puts("CTRL +Z    ");
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" undo");
    
    // Line 5: CTRL+Y redo
    sdtx.pos(0.5, grid_height - 3.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for CTRL+Y
    sdtx.puts("CTRL +Y    ");
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" redo");
    
    // Line 6: CTRL+S toggle
    sdtx.pos(0.5, grid_height - 2.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for CTRL+S
    sdtx.puts("CTRL +S    ");
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" toggle");
    
    // Line 7: ESC cancels
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



/// Push the current state onto the undo stack.
fn pushUndoSnapshot() void {
    const current_state = input_buffer[0..input_len];
    undo_redo_system.pushSnapshot(current_state);
}

/// Perform "undo" (Ctrl+Z). Restore the last snapshot from undo system.
fn undoAction() void {
    const current_state = input_buffer[0..input_len];
    if (undo_redo_system.undo(current_state)) |snapshot| {
        input_len = snapshot.len;
        @memcpy(input_buffer[0..snapshot.len], snapshot.slice());
        parseInput();
    }
}

/// Perform "redo" (Ctrl+Y). Opposite of undo.
fn redoAction() void {
    const current_state = input_buffer[0..input_len];
    if (undo_redo_system.redo(current_state)) |snapshot| {
        input_len = snapshot.len;
        @memcpy(input_buffer[0..snapshot.len], snapshot.slice());
        parseInput();
    }
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
            
            // Handle Ctrl+S (toggle XML mode)
            if (key == .S and (modifiers & 0x02) != 0) {
                const new_mode = xml_gen.toggleXMLMode();
                const mode_name = switch (new_mode) {
                    .regular => "regular XML tags",
                    .self_closing => "self-closing XML tags",
                };
                std.log.info("Toggled to {s} mode", .{mode_name});
                parseInput(); // Regenerate XML with new mode
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
    std.log.info("   CTRL+S = toggle between regular and self-closing XML tags", .{});
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
    // Test that we can create and restore snapshots using the undo/redo system
    var test_system = undo_redo.UndoRedoSystem.init();
    
    // Test snapshot creation
    const test_data = "hello";
    test_system.pushSnapshot(test_data);
    try std.testing.expect(test_system.canUndo());
    try std.testing.expect(!test_system.canRedo());
    
    // Test undo
    const current_data = "world";
    if (test_system.undo(current_data)) |snapshot| {
        try std.testing.expectEqualStrings(snapshot.slice(), "hello");
        try std.testing.expect(test_system.canRedo());
    } else {
        try std.testing.expect(false); // Should have been able to undo
    }
    
    // Test redo
    if (test_system.redo("hello")) |snapshot| {
        try std.testing.expectEqualStrings(snapshot.slice(), "world");
    } else {
        try std.testing.expect(false); // Should have been able to redo
    }
}

test "undo/redo stack operations" {
    // Test the undo stack directly
    var test_stack = undo_redo.UndoStack(undo_redo.StateSnapshot, 10).init();
    
    // Test that we can push and pop snapshots
    const snap1 = undo_redo.createSnapshot("abc");
    const snap2 = undo_redo.createSnapshot("hello");
    
    // Push snapshots
    test_stack.push(snap1);
    test_stack.push(snap2);
    try std.testing.expect(test_stack.len() == 2);
    
    // Pop and verify
    const popped = test_stack.pop() orelse unreachable;
    try std.testing.expect(popped.len == 5);
    try std.testing.expectEqualStrings(popped.slice(), "hello");
    
    const popped2 = test_stack.pop() orelse unreachable;
    try std.testing.expect(popped2.len == 3);
    try std.testing.expectEqualStrings(popped2.slice(), "abc");
    
    try std.testing.expect(test_stack.len() == 0);
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
    // Test with a long tag that should wrap
    const input = "div\tclass\tThis-is-a-very-long-class-name-that-should-definitely-wrap-at-the-specified-character-limit-to-test-our-wrapping-functionality-properly";
    const result = xml_gen.parseAndGenerateXML(input);
    
    // Verify that newlines were inserted in the display version
    const display_result = result.xml_display[0..result.xml_display_len];
    const has_newlines = std.mem.indexOf(u8, display_result, "\n") != null;
    try std.testing.expect(has_newlines);
    
    // Verify the line length is approximately correct (should be around 42 chars per line)
    var lines = std.mem.splitScalar(u8, display_result, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len > 0) {
            try std.testing.expect(line.len <= 42); // Should not exceed MAX_CHARS_PER_LINE
            line_count += 1;
        }
    }
    try std.testing.expect(line_count >= 2); // Should have wrapped into at least 2 lines
}

test "XML mode toggle functionality" {
    // Save original mode and restore it at the end
    const original_mode = xml_gen.getXMLMode();
    defer xml_gen.setXMLMode(original_mode);
    
    // Start in regular mode 
    xml_gen.setXMLMode(.regular);
    try std.testing.expect(xml_gen.getXMLMode() == .regular);
    
    // Test regular mode output
    const regular_result = xml_gen.parseAndGenerateXML("div\tclass\tcontainer");
    const regular_xml = std.mem.sliceTo(&regular_result.xml, 0);
    try std.testing.expectEqualStrings("<div class=\"container\">\n\n</div>", regular_xml);
    
    // Toggle to self-closing mode
    const new_mode = xml_gen.toggleXMLMode();
    try std.testing.expect(new_mode == .self_closing);
    try std.testing.expect(xml_gen.getXMLMode() == .self_closing);
    
    // Test self-closing mode output
    const self_closing_result = xml_gen.parseAndGenerateXML("div\tclass\tcontainer");
    const self_closing_xml = std.mem.sliceTo(&self_closing_result.xml, 0);
    try std.testing.expectEqualStrings("<div class=\"container\" />\n", self_closing_xml);
    
    // Toggle back to regular mode
    const back_to_regular = xml_gen.toggleXMLMode();
    try std.testing.expect(back_to_regular == .regular);
    try std.testing.expect(xml_gen.getXMLMode() == .regular);
}

test "self-closing XML with boolean attributes" {
    // Save original mode and restore it at the end
    const original_mode = xml_gen.getXMLMode();
    defer xml_gen.setXMLMode(original_mode);
    
    // Test self-closing mode with boolean attributes
    xml_gen.setXMLMode(.self_closing);
    
    const result = xml_gen.parseAndGenerateXML("input\ttype\ttext\thidden\t\trequired");
    const xml_str = std.mem.sliceTo(&result.xml, 0);
    try std.testing.expectEqualStrings("<input type=\"text\" hidden required />\n", xml_str);
}

test "self-closing XML with no attributes" {
    // Save original mode and restore it at the end
    const original_mode = xml_gen.getXMLMode();
    defer xml_gen.setXMLMode(original_mode);
    
    // Test self-closing mode with no attributes
    xml_gen.setXMLMode(.self_closing);
    
    const result = xml_gen.parseAndGenerateXML("br");
    const xml_str = std.mem.sliceTo(&result.xml, 0);
    try std.testing.expectEqualStrings("<br />\n", xml_str);
}



// Parse the input buffer and generate XML using the XML generator module
fn parseInput() void {
    const input_slice = input_buffer[0..input_len];
    const result = xml_gen.parseAndGenerateXML(input_slice);
    
    // Copy results to app state
    xml_output = result.xml;
    xml_len = result.xml_len;
    xml_display = result.xml_display;
    xml_display_len = result.xml_display_len;
}





// Test function to parse input string and return XML - delegates to XML generator
fn parseInputString(input: []const u8) [8192]u8 {
    return xml_gen.parseInputString(input);
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
