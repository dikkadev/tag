//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const sgfx = sokol.gfx;
const slog = sokol.log;
const sglue = sokol.glue;
const sdtx = sokol.debugtext;

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
var should_close_and_process = false;
var large_text_context: sdtx.Context = undefined;
var parsed_data: ParsedInput = ParsedInput{};
var xml_output: [8192]u8 = undefined;
var xml_len: usize = 0;

// Text scaling factors - adjust these to change text sizes
var input_text_scale: f32 = 1.3;  // Higher value = smaller text
var hint_text_scale: f32 = 1.15;   // Higher value = smaller text

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
        .canvas_width = 320,   // Smaller canvas = larger text (about 2x bigger)
        .canvas_height = 240,
    });
    
    @memset(&input_buffer, 0);
    input_len = 0;
    
    // Initialize the XML output with placeholder
    parseInput();
    
    std.log.info("Tag UI initialized with XML generation", .{});
}

export fn frame() void {
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
    
    // Display the generated XML instead of raw input
    if (xml_len > 0) {
        xml_output[xml_len] = 0; // Ensure null termination
        const xml_slice: [:0]const u8 = xml_output[0..xml_len :0];
        sdtx.puts(xml_slice);
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
    
    // Render hint text at bottom left corner (normal size) - 3 lines with colors
    // Line 1: ENTER closes and processes
    sdtx.pos(0.5, grid_height - 3.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for ENTER
    sdtx.puts("ENTER     "); // Padded to 10 chars to align with CTRL+ENTER
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" close and type");
    
    // Line 2: CTRL+ENTER clipboard
    sdtx.pos(0.5, grid_height - 2.5);
    sdtx.color3f(0.4, 0.8, 0.4); // Green for CTRL+ENTER
    sdtx.puts("CTRL+ENTER"); // 10 chars - reference length
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" clipboard");
    
    // Line 3: ESC cancels
    sdtx.pos(0.5, grid_height - 1.5);
    sdtx.color3f(0.8, 0.4, 0.4); // Red for ESC
    sdtx.puts("ESC       "); // Padded to 10 chars to align with CTRL+ENTER
    sdtx.color3f(0.7, 0.7, 0.7); // Gray for explanation
    sdtx.puts(" cancel");
    
    // Draw both contexts
    sdtx.contextDraw(large_text_context);
    sdtx.draw(); // Draw the default context
    
    sgfx.endPass();
    sgfx.commit();
    
    // Check if we should close and process
    if (should_close_and_process) {
        // Execute the code that should run before app exit
        processTextAndClose();
    }
}

fn processTextAndClose() void {
    std.log.info("🔄 Processing typed text before closing...", .{});
    std.log.info("📝 Final text content: '{s}'", .{input_buffer[0..input_len]});
    std.log.info("🏷️  Final generated XML: '{s}'", .{xml_output[0..xml_len]});
    
    // Here you can add any processing logic you need
    // For example: save to file, send to clipboard, etc.
    
    std.log.info("✅ Processing complete. Closing application.", .{});
    sapp.quit();
}

export fn event(e: [*c]const sapp.Event) void {
    const event_ptr = @as(*const sapp.Event, @ptrCast(e));
    
    switch (event_ptr.type) {
        .KEY_DOWN => {
            const key = event_ptr.key_code;
            const modifiers = event_ptr.modifiers;
            
            if (key == .ESCAPE) {
                sapp.quit();
                return;
            }
            
            if (key == .ENTER) {
                const is_ctrl = (modifiers & 0x02) != 0;
                const is_shift = (modifiers & 0x01) != 0;
                
                if (is_ctrl or is_shift) {
                    std.log.info("📋 CLIPBOARD: '{s}'", .{xml_output[0..xml_len]});
                    // In a real app, you'd copy to system clipboard here
                    std.log.info("🏁 Final generated XML: '{s}'", .{xml_output[0..xml_len]});
                    sapp.quit();
                } else {
                    // Regular enter now closes and processes
                    std.log.info("📥 Regular ENTER pressed - will close and process", .{});
                    should_close_and_process = true;
                }
                return;
            }
            
            if (key == .TAB) {
                // Add tab support
                if (input_len < input_buffer.len - 1) {
                    input_buffer[input_len] = '\t';
                    input_len += 1;
                    parseInput(); // Update XML when input changes
                    std.log.info("⇥ Added tab character", .{});
                }
                return;
            }
            
            if (key == .BACKSPACE) {
                if (input_len > 0) {
                    input_len -= 1;
                    input_buffer[input_len] = 0;
                    parseInput(); // Update XML when input changes
                    std.log.info("⌫ Backspace", .{});
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
                    std.log.info("✏️  Added '{c}'", .{char});
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
    std.log.info("🚀 Starting Tag UI Application", .{});
    std.log.info("💡 Instructions:", .{});
    std.log.info("   ESC = quit immediately", .{});
    std.log.info("   ENTER = close and process text", .{});
    std.log.info("   TAB = add tab character", .{});
    std.log.info("   CTRL+ENTER or SHIFT+ENTER = copy to clipboard and quit", .{});
    std.log.info("   Type to add characters", .{});
    std.log.info("", .{});
    
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .event_cb = event,
        .cleanup_cb = cleanup,
        .width = 450,
        .height = 300,
        .window_title = "Tag - Text Input UI",
        .logger = .{ .func = slog.func },
    });
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

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("zig_lib");

// Parse the input buffer and populate parsed_data
fn parseInput() void {
    parsed_data.clear();
    
    if (input_len == 0) {
        generateXML();
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
}

// Clean tag/attribute names: spaces -> underscores, trim whitespace
fn cleanTagName(input: []const u8) []const u8 {
    var cleaned: [256]u8 = undefined;
    var cleaned_len: usize = 0;
    
    // Trim and clean
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    for (trimmed) |char| {
        if (cleaned_len >= 255) break;
        if (char == ' ') {
            cleaned[cleaned_len] = '_';
        } else if ((char >= 'A' and char <= 'Z') or 
                   (char >= 'a' and char <= 'z') or 
                   (char >= '0' and char <= '9') or 
                   char == '_' or char == '-') {
            cleaned[cleaned_len] = char;
        }
        cleaned_len += 1;
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
                    appendToXML(parsed_data.attributes[i + 1].slice());
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
