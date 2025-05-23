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

// App state
var input_buffer: [4096]u8 = undefined;
var input_len: usize = 0;
var should_close_and_process = false;
var large_text_context: sdtx.Context = undefined;

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
    
    std.log.info("Tag UI initialized with text rendering", .{});
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
    
    // First, render the larger input text using the large text context
    sdtx.setContext(large_text_context);
    sdtx.canvas(@as(f32, @floatFromInt(sapp.width())) / input_text_scale, @as(f32, @floatFromInt(sapp.height())) / input_text_scale);
    
    // Render typed text starting from top left
    sdtx.pos(0.5, 1.0);
    sdtx.color3f(0.9, 0.9, 0.6);
    
    if (input_len > 0) {
        // Create null-terminated string for display
        input_buffer[input_len] = 0; // Ensure null termination
        const text_slice: [:0]const u8 = input_buffer[0..input_len :0];
        sdtx.puts(text_slice);
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
                    std.log.info("📋 CLIPBOARD: '{s}'", .{input_buffer[0..input_len]});
                    // In a real app, you'd copy to system clipboard here
                    std.log.info("🏁 Final typed text: '{s}'", .{input_buffer[0..input_len]});
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
                    std.log.info("⇥ Added tab character", .{});
                }
                return;
            }
            
            if (key == .BACKSPACE) {
                if (input_len > 0) {
                    input_len -= 1;
                    input_buffer[input_len] = 0;
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

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "use other module" {
    try std.testing.expectEqual(@as(i32, 150), lib.add(100, 50));
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("zig_lib");
