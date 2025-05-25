#define SUI_IMPLEMENTATION
#include "../SUI.h"

// C wrapper functions for Zig to call
void sui_init_keyboard(void) {
    SUIInit(1); // 1 = keyboard mode
}

void sui_press_key(int keycode) {
    SUIPressKey(keycode);
}

void sui_send_shift_enter(void) {
    // Press Shift
    _input.ki.wVk = VK_SHIFT;
    _input.ki.dwFlags = 0;
    SendInput(1, &_input, sizeof(INPUT));
    
    // Small delay
    Sleep(10);
    
    // Press Enter
    _input.ki.wVk = VK_RETURN;
    _input.ki.dwFlags = 0;
    SendInput(1, &_input, sizeof(INPUT));
    
    // Small delay
    Sleep(10);
    
    // Release Enter
    _input.ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(1, &_input, sizeof(INPUT));
    
    // Small delay
    Sleep(10);
    
    // Release Shift
    _input.ki.wVk = VK_SHIFT;
    _input.ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(1, &_input, sizeof(INPUT));
}

void sui_type_string(const char* text) {
    if (!text) return;
    
    for (int i = 0; text[i] != '\0'; i++) {
        char c = text[i];
        
        // Convert character to virtual key code
        SHORT vk = VkKeyScanA(c);
        if (vk == -1) continue; // Skip unmappable characters
        
        BYTE key = LOBYTE(vk);
        BYTE shift_state = HIBYTE(vk);
        
        // Press shift if needed
        if (shift_state & 1) {
            _input.ki.wVk = VK_SHIFT;
            _input.ki.dwFlags = 0;
            SendInput(1, &_input, sizeof(INPUT));
        }
        
        // Press the key
        _input.ki.wVk = key;
        _input.ki.dwFlags = 0;
        SendInput(1, &_input, sizeof(INPUT));
        
        // Release the key
        _input.ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput(1, &_input, sizeof(INPUT));
        
        // Release shift if it was pressed
        if (shift_state & 1) {
            _input.ki.wVk = VK_SHIFT;
            _input.ki.dwFlags = KEYEVENTF_KEYUP;
            SendInput(1, &_input, sizeof(INPUT));
        }
        
        // Small delay between characters
        Sleep(10);
    }
} 