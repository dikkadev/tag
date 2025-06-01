//! Undo/Redo system for managing application state snapshots
//! Provides snapshot-based state management with configurable history limits

const std = @import("std");

// ────────────────────────────────────────────────────────────────────────────────
// Data structures
// ────────────────────────────────────────────────────────────────────────────────

pub const StateSnapshot = struct {
    buffer: [4096]u8 = undefined,
    len: usize = 0,
    
    pub fn init() StateSnapshot {
        return StateSnapshot{};
    }
    
    pub fn setFromSlice(self: *StateSnapshot, data: []const u8) void {
        self.len = @min(data.len, 4095);
        @memcpy(self.buffer[0..self.len], data[0..self.len]);
        self.buffer[self.len] = 0; // null terminate
    }
    
    pub fn slice(self: *const StateSnapshot) []const u8 {
        return self.buffer[0..self.len];
    }
    
    pub fn isEmpty(self: *const StateSnapshot) bool {
        return self.len == 0;
    }
};

// ────────────────────────────────────────────────────────────────────────────────
// Stack implementation for undo/redo
// ────────────────────────────────────────────────────────────────────────────────

pub fn UndoStack(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        
        items: [capacity]T = undefined,
        count: usize = 0,
        
        pub fn init() Self {
            return Self{};
        }
        
        pub fn push(self: *Self, item: T) void {
            if (self.count < capacity) {
                self.items[self.count] = item;
                self.count += 1;
            } else {
                // Stack is full, shift everything down and add new item at end
                for (1..capacity) |i| {
                    self.items[i - 1] = self.items[i];
                }
                self.items[capacity - 1] = item;
            }
        }
        
        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            self.count -= 1;
            return self.items[self.count];
        }
        
        pub fn peek(self: *const Self) ?T {
            if (self.count == 0) return null;
            return self.items[self.count - 1];
        }
        
        pub fn clear(self: *Self) void {
            self.count = 0;
        }
        
        pub fn len(self: *const Self) usize {
            return self.count;
        }
        
        pub fn append(self: *Self, item: T) !void {
            self.push(item);
        }
    };
}

// ────────────────────────────────────────────────────────────────────────────────
// Undo/Redo system
// ────────────────────────────────────────────────────────────────────────────────

pub const UndoRedoSystem = struct {
    const UNDO_STACK_SIZE = 50;
    const REDO_STACK_SIZE = 50;
    
    undo_stack: UndoStack(StateSnapshot, UNDO_STACK_SIZE),
    redo_stack: UndoStack(StateSnapshot, REDO_STACK_SIZE),
    
    pub fn init() UndoRedoSystem {
        return UndoRedoSystem{
            .undo_stack = UndoStack(StateSnapshot, UNDO_STACK_SIZE).init(),
            .redo_stack = UndoStack(StateSnapshot, REDO_STACK_SIZE).init(),
        };
    }
    
    pub fn pushSnapshot(self: *UndoRedoSystem, current_state: []const u8) void {
        var snapshot = StateSnapshot.init();
        snapshot.setFromSlice(current_state);
        self.undo_stack.push(snapshot);
        
        // Clear redo stack when new snapshot is added
        self.redo_stack.clear();
    }
    
    pub fn undo(self: *UndoRedoSystem, current_state: []const u8) ?StateSnapshot {
        if (self.undo_stack.len() == 0) return null;
        
        // Save current state to redo stack
        var current_snapshot = StateSnapshot.init();
        current_snapshot.setFromSlice(current_state);
        self.redo_stack.push(current_snapshot);
        
        // Return previous state from undo stack
        return self.undo_stack.pop();
    }
    
    pub fn redo(self: *UndoRedoSystem, current_state: []const u8) ?StateSnapshot {
        if (self.redo_stack.len() == 0) return null;
        
        // Save current state to undo stack
        var current_snapshot = StateSnapshot.init();
        current_snapshot.setFromSlice(current_state);
        self.undo_stack.push(current_snapshot);
        
        // Return next state from redo stack
        return self.redo_stack.pop();
    }
    
    pub fn canUndo(self: *const UndoRedoSystem) bool {
        return self.undo_stack.len() > 0;
    }
    
    pub fn canRedo(self: *const UndoRedoSystem) bool {
        return self.redo_stack.len() > 0;
    }
    
    pub fn clear(self: *UndoRedoSystem) void {
        self.undo_stack.clear();
        self.redo_stack.clear();
    }
    
    pub fn getUndoStackSize(self: *const UndoRedoSystem) usize {
        return self.undo_stack.len();
    }
    
    pub fn getRedoStackSize(self: *const UndoRedoSystem) usize {
        return self.redo_stack.len();
    }
};

// ────────────────────────────────────────────────────────────────────────────────
// Convenience function for creating state snapshots
// ────────────────────────────────────────────────────────────────────────────────

pub fn createSnapshot(data: []const u8) StateSnapshot {
    var snapshot = StateSnapshot.init();
    snapshot.setFromSlice(data);
    return snapshot;
} 