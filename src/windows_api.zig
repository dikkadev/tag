//! Windows API declarations and helper functions

const std = @import("std");
const windows = std.os.windows;

// ────────────────────────────────────────────────────────────────────────────────
// Clipboard API
// ────────────────────────────────────────────────────────────────────────────────
extern "user32" fn OpenClipboard(hWndNewOwner: ?windows.HWND) c_int;
extern "user32" fn CloseClipboard() c_int;
extern "user32" fn EmptyClipboard() c_int;
extern "user32" fn SetClipboardData(uFormat: u32, hMem: ?windows.HANDLE) ?windows.HANDLE;
extern "user32" fn GetClipboardData(uFormat: u32) ?windows.HANDLE;
extern "kernel32" fn GlobalAlloc(uFlags: u32, dwBytes: usize) ?windows.HANDLE;
extern "kernel32" fn GlobalLock(hMem: ?windows.HANDLE) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: ?windows.HANDLE) c_int;

pub const CF_TEXT: u32 = 1;
pub const GMEM_MOVEABLE: u32 = 0x0002;

// ────────────────────────────────────────────────────────────────────────────────
// Window positioning API
// ────────────────────────────────────────────────────────────────────────────────
extern "user32" fn GetCursorPos(lpPoint: *POINT) windows.BOOL;
extern "user32" fn MonitorFromPoint(pt: POINT, dwFlags: u32) ?windows.HANDLE;
extern "user32" fn GetMonitorInfoW(hMonitor: windows.HANDLE, lpmi: *MONITORINFO) windows.BOOL;
extern "user32" fn FindWindowW(lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16) ?windows.HWND;
extern "user32" fn SetWindowPos(hWnd: windows.HWND, hWndInsertAfter: ?windows.HWND, X: i32, Y: i32, cx: i32, cy: i32, uFlags: u32) windows.BOOL;

pub const POINT = extern struct {
    x: i32,
    y: i32,
};

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const MONITORINFO = extern struct {
    cbSize: u32,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: u32,
};

pub const MONITOR_DEFAULTTONEAREST: u32 = 0x00000002;
pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_NOACTIVATE: u32 = 0x0010;

// ────────────────────────────────────────────────────────────────────────────────
// Clipboard helper functions
// ────────────────────────────────────────────────────────────────────────────────
pub fn getClipboardText() ?[]u8 {
    if (OpenClipboard(null) == 0) {
        std.log.err("Failed to open clipboard for reading", .{});
        return null;
    }
    defer _ = CloseClipboard();
    
    const hData = GetClipboardData(CF_TEXT) orelse {
        std.log.warn("No text data in clipboard", .{});
        return null;
    };
    
    const pData = GlobalLock(hData) orelse {
        std.log.err("Failed to lock clipboard data", .{});
        return null;
    };
    defer _ = GlobalUnlock(hData);
    
    // Cast to a null-terminated string and find the length
    const clipboard_cstr: [*:0]const u8 = @ptrCast(pData);
    const clipboard_len = std.mem.len(clipboard_cstr);
    
    if (clipboard_len == 0) {
        return null;
    }
    
    // Allocate memory for the clipboard text
    const clipboard_text = std.heap.page_allocator.alloc(u8, clipboard_len) catch {
        std.log.err("Failed to allocate memory for clipboard text", .{});
        return null;
    };
    
    @memcpy(clipboard_text, clipboard_cstr[0..clipboard_len]);
    return clipboard_text;
}

pub fn copyToClipboard(text: []const u8) bool {
    if (OpenClipboard(null) == 0) {
        std.log.err("Failed to open clipboard", .{});
        return false;
    }
    defer _ = CloseClipboard();
    
    if (EmptyClipboard() == 0) {
        std.log.err("Failed to empty clipboard", .{});
        return false;
    }
    
    // Allocate global memory for the text (including null terminator)
    const hMem = GlobalAlloc(GMEM_MOVEABLE, text.len + 1) orelse {
        std.log.err("Failed to allocate global memory", .{});
        return false;
    };
    
    // Lock the memory and copy text
    if (GlobalLock(hMem)) |pMem| {
        const dest: [*]u8 = @ptrCast(pMem);
        @memcpy(dest[0..text.len], text);
        dest[text.len] = 0; // null terminator
        _ = GlobalUnlock(hMem);
        
        // Set clipboard data
        if (SetClipboardData(CF_TEXT, hMem) == null) {
            std.log.err("Failed to set clipboard data", .{});
            return false;
        }
        
        return true;
    } else {
        std.log.err("Failed to lock global memory", .{});
        return false;
    }
}

// ────────────────────────────────────────────────────────────────────────────────
// Window positioning helper functions
// ────────────────────────────────────────────────────────────────────────────────
pub fn calculateDesiredWindowPosition() struct { x: i32, y: i32, calculated: bool } {
    if (@import("builtin").target.os.tag != .windows) {
        return .{ .x = 0, .y = 0, .calculated = false };
    }
    
    // Get current mouse cursor position
    var cursor_pos: POINT = undefined;
    if (GetCursorPos(&cursor_pos) == 0) {
        std.log.warn("Failed to get cursor position", .{});
        return .{ .x = 0, .y = 0, .calculated = false };
    }
    
    // Find the monitor containing the cursor
    const hMonitor = MonitorFromPoint(cursor_pos, MONITOR_DEFAULTTONEAREST) orelse {
        std.log.warn("Failed to get monitor from cursor position", .{});
        return .{ .x = 0, .y = 0, .calculated = false };
    };
    
    // Get monitor information
    var monitor_info: MONITORINFO = undefined;
    monitor_info.cbSize = @sizeOf(MONITORINFO);
    if (GetMonitorInfoW(hMonitor, &monitor_info) == 0) {
        std.log.warn("Failed to get monitor information", .{});
        return .{ .x = 0, .y = 0, .calculated = false };
    }
    
    // Calculate position for top-left area of the target monitor (not centered)
    const margin_x: i32 = 50;  // Some margin from the edge
    const margin_y: i32 = 50;  // Some margin from the top
    
    const desired_x = monitor_info.rcWork.left + margin_x;
    const desired_y = monitor_info.rcWork.top + margin_y;
    
    std.log.info("Calculated window position for monitor containing mouse cursor: ({}, {})", .{ desired_x, desired_y });
    return .{ .x = desired_x, .y = desired_y, .calculated = true };
}

pub fn positionWindow(window_title: []const u8, x: i32, y: i32) bool {
    if (@import("builtin").target.os.tag != .windows) {
        return false;
    }
    
    // Find our window using the window title
    const window_title_utf16 = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, window_title) catch {
        std.log.warn("Failed to convert window title to UTF-16", .{});
        return false;
    };
    defer std.heap.page_allocator.free(window_title_utf16);
    
    const hwnd = FindWindowW(null, window_title_utf16.ptr) orelse {
        // Window might not be ready yet
        return false;
    };
    
    // Position the window at the calculated location
    if (SetWindowPos(hwnd, null, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE) == 0) {
        std.log.warn("Failed to position window", .{});
        return false;
    }
    
    std.log.info("Positioned window at ({}, {}) on monitor containing mouse cursor", .{ x, y });
    return true;
} 