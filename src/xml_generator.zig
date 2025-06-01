//! XML generation from tab-separated input
//! Converts input like "div<TAB>class<TAB>container<TAB>id<TAB>main" to XML output

const std = @import("std");

// ────────────────────────────────────────────────────────────────────────────────
// Data structures
// ────────────────────────────────────────────────────────────────────────────────

pub const Token = struct {
    text: [256]u8 = undefined,
    len: usize = 0,
    
    pub fn init() Token {
        return Token{};
    }
    
    pub fn set(self: *Token, text: []const u8) void {
        self.len = @min(text.len, 255);
        @memcpy(self.text[0..self.len], text[0..self.len]);
        self.text[self.len] = 0; // null terminate
    }
    
    pub fn slice(self: *const Token) []const u8 {
        return self.text[0..self.len];
    }
    
    pub fn isEmpty(self: *const Token) bool {
        return self.len == 0;
    }
};

pub const ParsedInput = struct {
    tag_name: Token = Token.init(),
    attributes: [16]Token = [_]Token{Token.init()} ** 16,
    attr_count: usize = 0,
    is_boolean: [16]bool = [_]bool{false} ** 16, // Track which attributes are boolean
    
    pub fn clear(self: *ParsedInput) void {
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

// Text wrapping constants - calculated for fixed window size 450x180
// Window width: 450px, text scale: 1.3, effective width: ~346px
// Character width: ~8px, so ~43 chars fit, using 42 for good balance
const MAX_CHARS_PER_LINE: usize = 42; // Good balance of space usage and safety
const MAX_LINES: usize = 8; // Maximum lines that fit in the display area

// XML display formatting constants
const XML_EXTRA_NEWLINES = "\n\n\n"; // Extra newlines for better visual separation

// ────────────────────────────────────────────────────────────────────────────────
// XML generation mode
// ────────────────────────────────────────────────────────────────────────────────

pub const XMLMode = enum {
    regular,     // <tag>\n\n</tag>
    self_closing // <tag />\n
};

// Global state for XML generation mode
var xml_mode: XMLMode = .regular;

pub fn toggleXMLMode() XMLMode {
    xml_mode = switch (xml_mode) {
        .regular => .self_closing,
        .self_closing => .regular,
    };
    return xml_mode;
}

pub fn getXMLMode() XMLMode {
    return xml_mode;
}

pub fn setXMLMode(mode: XMLMode) void {
    xml_mode = mode;
}

// ────────────────────────────────────────────────────────────────────────────────
// Main parsing and generation functions
// ────────────────────────────────────────────────────────────────────────────────

pub fn parseAndGenerateXML(input: []const u8) struct { 
    xml: [8192]u8, 
    xml_len: usize, 
    xml_display: [8192]u8, 
    xml_display_len: usize 
} {
    var parsed_data = ParsedInput{};
    
    // Parse the input
    parseInputInternal(input, &parsed_data);
    
    // Generate both XML outputs
    var xml_output: [8192]u8 = undefined;
    var xml_len: usize = 0;
    var xml_display: [8192]u8 = undefined;
    var xml_display_len: usize = 0;
    
    generateXMLInternal(&parsed_data, &xml_output, &xml_len);
    generateXMLDisplayInternal(&parsed_data, &xml_display, &xml_display_len);
    
    return .{
        .xml = xml_output,
        .xml_len = xml_len,
        .xml_display = xml_display,
        .xml_display_len = xml_display_len,
    };
}

fn parseInputInternal(input: []const u8, parsed_data: *ParsedInput) void {
    parsed_data.clear();
    
    if (input.len == 0) {
        return;
    }
    
    // Split by tabs to get tokens
    var tokens: [32]Token = [_]Token{Token.init()} ** 32;
    var token_count: usize = 0;
    
    var start: usize = 0;
    var i: usize = 0;
    
    while (i <= input.len) : (i += 1) {
        if (i == input.len or input[i] == '\t') {
            // Always add a token, even if empty (for consecutive tabs)
            if (token_count < 32) {
                if (start < i) {
                    tokens[token_count].set(input[start..i]);
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
}

// ────────────────────────────────────────────────────────────────────────────────
// String cleaning functions
// ────────────────────────────────────────────────────────────────────────────────

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

// ────────────────────────────────────────────────────────────────────────────────
// XML generation functions
// ────────────────────────────────────────────────────────────────────────────────

fn generateXMLInternal(parsed_data: *const ParsedInput, xml_output: *[8192]u8, xml_len: *usize) void {
    xml_len.* = 0;
    @memset(xml_output, 0); // Clear the buffer
    
    if (parsed_data.tag_name.isEmpty()) {
        // Show placeholder if no input
        const placeholder = "(type something...)";
        @memcpy(xml_output[0..placeholder.len], placeholder);
        xml_len.* = placeholder.len;
        xml_output[xml_len.*] = 0; // null terminate
        return;
    }
    
    const tag_name = parsed_data.tag_name.slice();
    
    // Build opening tag with attributes
    appendToXML(xml_output, xml_len, "<");
    appendToXML(xml_output, xml_len, tag_name);
    
    // Add attributes using boolean flags
    var i: usize = 0;
    while (i < parsed_data.attr_count) {
        if (!parsed_data.attributes[i].isEmpty()) {
            appendToXML(xml_output, xml_len, " ");
            appendToXML(xml_output, xml_len, parsed_data.attributes[i].slice()); // attribute name
            
            if (!parsed_data.is_boolean[i]) {
                // This is a key-value pair, next slot has the value
                if (i + 1 < parsed_data.attr_count and !parsed_data.attributes[i + 1].isEmpty()) {
                    appendToXML(xml_output, xml_len, "=\"");
                    appendEscapedToXML(xml_output, xml_len, parsed_data.attributes[i + 1].slice());
                    appendToXML(xml_output, xml_len, "\"");
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
    
    // Handle different XML modes
    switch (xml_mode) {
        .regular => {
            appendToXML(xml_output, xml_len, ">\n\n</");
            appendToXML(xml_output, xml_len, tag_name);
            appendToXML(xml_output, xml_len, ">");
        },
        .self_closing => {
            appendToXML(xml_output, xml_len, " />\n");
        },
    }
    
    // Ensure null termination
    if (xml_len.* < xml_output.len) {
        xml_output[xml_len.*] = 0;
    }
}

fn appendToXML(xml_output: *[8192]u8, xml_len: *usize, text: []const u8) void {
    const remaining = xml_output.len - xml_len.*;
    const to_copy = @min(text.len, remaining);
    if (to_copy > 0) {
        @memcpy(xml_output[xml_len.*..xml_len.* + to_copy], text[0..to_copy]);
        xml_len.* += to_copy;
    }
}

fn appendEscapedToXML(xml_output: *[8192]u8, xml_len: *usize, text: []const u8) void {
    for (text) |char| {
        if (xml_len.* >= xml_output.len - 6) break; // Reserve space for longest escape sequence
        
        switch (char) {
            '"' => {
                appendToXML(xml_output, xml_len, "&quot;");
            },
            '&' => {
                appendToXML(xml_output, xml_len, "&amp;");
            },
            '<' => {
                appendToXML(xml_output, xml_len, "&lt;");
            },
            '>' => {
                appendToXML(xml_output, xml_len, "&gt;");
            },
            else => {
                if (xml_len.* < xml_output.len) {
                    xml_output[xml_len.*] = char;
                    xml_len.* += 1;
                }
            },
        }
    }
}

// ────────────────────────────────────────────────────────────────────────────────
// XML display generation with text wrapping
// ────────────────────────────────────────────────────────────────────────────────

fn generateXMLDisplayInternal(parsed_data: *const ParsedInput, xml_display: *[8192]u8, xml_display_len: *usize) void {
    xml_display_len.* = 0;
    @memset(xml_display, 0); // Clear the buffer
    
    if (parsed_data.tag_name.isEmpty()) {
        // Show placeholder if no input
        const placeholder = "(type something...)";
        @memcpy(xml_display[0..placeholder.len], placeholder);
        xml_display_len.* = placeholder.len;
        xml_display[xml_display_len.*] = 0; // null terminate
        return;
    }
    
    const tag_name = parsed_data.tag_name.slice();
    
    // Build opening tag with attributes
    appendToXMLDisplayWithWrapping(xml_display, xml_display_len, "<");
    appendToXMLDisplayWithWrapping(xml_display, xml_display_len, tag_name);
    
    // Add attributes using boolean flags (same logic as regular XML)
    var i: usize = 0;
    while (i < parsed_data.attr_count) {
        if (!parsed_data.attributes[i].isEmpty()) {
            appendToXMLDisplayWithWrapping(xml_display, xml_display_len, " ");
            appendToXMLDisplayWithWrapping(xml_display, xml_display_len, parsed_data.attributes[i].slice()); // attribute name
            
            if (!parsed_data.is_boolean[i]) {
                // This is a key-value pair, next slot has the value
                if (i + 1 < parsed_data.attr_count and !parsed_data.attributes[i + 1].isEmpty()) {
                    appendToXMLDisplayWithWrapping(xml_display, xml_display_len, "=\"");
                    appendEscapedToXMLDisplayWithWrapping(xml_display, xml_display_len, parsed_data.attributes[i + 1].slice());
                    appendToXMLDisplayWithWrapping(xml_display, xml_display_len, "\"");
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
    
    // Handle different XML modes for display
    switch (xml_mode) {
        .regular => {
            // Enhanced visual spacing for display: add extra newlines to make empty line more visible
            appendToXMLDisplayWithWrapping(xml_display, xml_display_len, ">");
            appendToXMLDisplayWithWrapping(xml_display, xml_display_len, XML_EXTRA_NEWLINES);
            appendToXMLDisplayWithWrapping(xml_display, xml_display_len, "</");
            appendToXMLDisplayWithWrapping(xml_display, xml_display_len, tag_name);
            appendToXMLDisplayWithWrapping(xml_display, xml_display_len, ">");
        },
        .self_closing => {
            appendToXMLDisplayWithWrapping(xml_display, xml_display_len, " />");
            appendToXMLDisplayWithWrapping(xml_display, xml_display_len, "\n");
        },
    }
    
    // Ensure null termination
    if (xml_display_len.* < xml_display.len) {
        xml_display[xml_display_len.*] = 0;
    }
}

fn appendToXMLDisplayWithWrapping(xml_display: *[8192]u8, xml_display_len: *usize, text: []const u8) void {
    var current_line_length: usize = 0;
    
    // Count current line length by looking backwards to last newline
    if (xml_display_len.* > 0) {
        var i: usize = xml_display_len.*;
        while (i > 0) {
            i -= 1;
            if (xml_display[i] == '\n') {
                current_line_length = xml_display_len.* - i - 1;
                break;
            }
        } else {
            current_line_length = xml_display_len.*;
        }
    }
    
    for (text) |char| {
        if (xml_display_len.* >= xml_display.len - 1) break;
        
        // Check if we need to wrap
        if (current_line_length >= MAX_CHARS_PER_LINE and char != '\n') {
            // Add a line break
            xml_display[xml_display_len.*] = '\n';
            xml_display_len.* += 1;
            current_line_length = 0;
            
            if (xml_display_len.* >= xml_display.len - 1) break;
        }
        
        xml_display[xml_display_len.*] = char;
        xml_display_len.* += 1;
        
        if (char == '\n') {
            current_line_length = 0;
        } else {
            current_line_length += 1;
        }
    }
}

fn appendEscapedToXMLDisplayWithWrapping(xml_display: *[8192]u8, xml_display_len: *usize, text: []const u8) void {
    for (text) |char| {
        if (xml_display_len.* >= xml_display.len - 6) break; // Reserve space for longest escape sequence
        
        switch (char) {
            '"' => {
                appendToXMLDisplayWithWrapping(xml_display, xml_display_len, "&quot;");
            },
            '&' => {
                appendToXMLDisplayWithWrapping(xml_display, xml_display_len, "&amp;");
            },
            '<' => {
                appendToXMLDisplayWithWrapping(xml_display, xml_display_len, "&lt;");
            },
            '>' => {
                appendToXMLDisplayWithWrapping(xml_display, xml_display_len, "&gt;");
            },
            else => {
                const single_char = [1]u8{char};
                appendToXMLDisplayWithWrapping(xml_display, xml_display_len, &single_char);
            },
        }
    }
}

// ────────────────────────────────────────────────────────────────────────────────
// Test helper function
// ────────────────────────────────────────────────────────────────────────────────

pub fn parseInputString(input: []const u8) [8192]u8 {
    const result = parseAndGenerateXML(input);
    var output: [8192]u8 = undefined;
    @memcpy(output[0..result.xml_len], result.xml[0..result.xml_len]);
    @memset(output[result.xml_len..], 0);
    return output;
} 