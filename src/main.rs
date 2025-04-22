#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")] // Hide console window on Windows release builds

use env_logger::Env;
use egui::Key;
use std::error::Error;
use eframe::egui;
use egui::{ViewportBuilder, ViewportCommand};
use windows::Win32::Foundation::POINT;
use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;
use windows::Win32::Graphics::Gdi::{MonitorFromPoint, GetMonitorInfoW, MONITORINFOEXW, MONITOR_DEFAULTTONEAREST};

// New struct to hold the structured input
#[derive(Debug, Clone, Default)]
struct InputState {
    tag: String,
    attributes: Vec<(String, String)>,
}

struct App {
    input_state: InputState, // Use the new struct
    has_parse_error: bool,
    clipboard: Option<arboard::Clipboard>,
    tag_field_id: egui::Id, // Store the Id of the tag field for focus
    should_focus_tag: bool, // Flag to request focus on next frame
    focus_next_frame: Option<egui::Id>, // ID to focus on the next frame
}

impl App {
    fn new(_cc: &eframe::CreationContext<'_>) -> Self {
        let tag_field_id = egui::Id::new("tag_field"); // Create unique ID for the tag field
        Self {
            input_state: InputState::default(), // Initialize the new struct
            has_parse_error: false,
            clipboard: None,
            tag_field_id,
            should_focus_tag: true, // Focus on the first frame
            focus_next_frame: None, // Initialize to None
        }
    }
}

// Re-add ParsedData struct definition
#[derive(Debug, Clone)]
struct ParsedData {
    tag: String,
    // Use Option<String> for values to handle boolean attributes
    attributes: Vec<(String, Option<String>)>,
}

// Re-add clean_identifier function definition
/// Cleans a string to be a valid XML identifier (tag name or attribute key).
/// Replaces whitespace with underscores, then keeps only alphanumeric, underscore, and hyphen.
///
/// # Examples
/// ```
/// assert_eq!(clean_identifier(" my tag "), "my_tag");
/// assert_eq!(clean_identifier("invalid-chars!?"), "invalid-chars");
/// assert_eq!(clean_identifier("  "), "_"); // Multiple spaces become one underscore
/// assert_eq!(clean_identifier(" a b-c_d "), "a_b-c_d");
/// ```
fn clean_identifier(input: &str) -> String {
    // First, replace whitespace sequences with a single underscore
    let replaced_whitespace = input
        .split_whitespace()
        .collect::<Vec<&str>>()
        .join("_");

    // Then, filter characters
    replaced_whitespace
        .chars()
        .filter(|&c| c.is_alphanumeric() || c == '_' || c == '-')
        .collect()
}

// New function to build ParsedData from InputState
fn build_parsed_data(input_state: &InputState) -> Result<ParsedData, &'static str> {
    if input_state.tag.trim().is_empty() {
        return Err("Tag cannot be empty.");
    }
    let tag = clean_identifier(&input_state.tag);
    if tag.is_empty() {
        return Err("Tag contains invalid characters.");
    }

    let mut attributes = Vec::new();
    for (key, value) in &input_state.attributes {
        let cleaned_key = clean_identifier(key);
        // Only add attribute if key is not empty after cleaning
        if !cleaned_key.is_empty() {
            let cleaned_value = if value.trim().is_empty() {
                None // Treat empty value as boolean attribute
            } else {
                Some(value.trim().to_string()) // Keep value as is (trimmed)
            };
            attributes.push((cleaned_key, cleaned_value));
        } else if !key.trim().is_empty() {
            // Original key was not empty but cleaned key is -> invalid chars
             return Err("Attribute key contains invalid characters.");
        }
        // Ignore pairs where the original key was also empty
    }

    Ok(ParsedData { tag, attributes })
}

// Re-add generate_xml function definition
fn generate_xml(data: &ParsedData) -> String {
    let mut attributes_string = String::new();
    for (key, value_opt) in &data.attributes {
        match value_opt {
            Some(value) => {
                // Escape quotes within the attribute value
                let escaped_value = value.replace('"', "&quot;");
                // Escape quotes in format string
                attributes_string.push_str(&format!(" {}=\"{}\"", key, escaped_value));
            }
            None => {
                // Boolean attribute (no value)
                attributes_string.push_str(&format!(" {}", key));
            }
        }
    }
    // Format with newline and closing tag
    format!("<{}{}>\n\n</{}>", data.tag, attributes_string, data.tag)
}

impl eframe::App for App {
    fn update(&mut self, ctx: &eframe::egui::Context, _frame: &mut eframe::Frame) {
        // --- Focus Handling --- 
        // Apply focus request from the previous frame
        if let Some(id_to_focus) = self.focus_next_frame.take() {
            ctx.memory_mut(|mem| mem.request_focus(id_to_focus));
        }

        // Handle initial tag focus
        if self.should_focus_tag {
           // Use focus_next_frame mechanism for consistency
           self.focus_next_frame = Some(self.tag_field_id);
           self.should_focus_tag = false; // Reset the flag
       }

       // Variables to track focus for Tab logic
       let mut tag_focused = false;
       let mut last_attr_value_focused = false;
       let last_attr_index = self.input_state.attributes.len().saturating_sub(1);

       // Check current focus *before* handling input
       if let Some(focused_id) = ctx.memory(|mem| mem.focused()) {
           if focused_id == self.tag_field_id {
               tag_focused = true;
           }
           if !self.input_state.attributes.is_empty() {
               let last_val_id = egui::Id::new(format!("attr_val_{}", last_attr_index));
               if focused_id == last_val_id {
                   last_attr_value_focused = true;
               }
           }
       }

       // --- Input Processing --- 
       let mut escape_pressed = false;

       ctx.input(|i| {
           if i.key_pressed(Key::Escape) {
               log::info!("Escape pressed, attempting to exit cleanly.");
               escape_pressed = true;
           }

           // Handle Tab for adding attributes
           if i.key_pressed(Key::Tab) && i.modifiers.is_none() {
                log::trace!("Tab pressed. Tag focused: {}, Last Attr Val focused: {}", tag_focused, last_attr_value_focused);
                let mut should_add_attribute = false;

                if tag_focused && self.input_state.attributes.is_empty() {
                    log::debug!("Tab from tag (no attributes), adding first attribute.");
                    should_add_attribute = true;
                } else if last_attr_value_focused {
                    log::debug!("Tab from last attribute value, adding new attribute.");
                    should_add_attribute = true;
                }

                if should_add_attribute {
                    self.input_state.attributes.push((String::new(), String::new()));
                    // Get the index of the newly added attribute
                    let new_index = self.input_state.attributes.len() - 1;
                    // Set focus target for the *next* frame
                    self.focus_next_frame = Some(egui::Id::new(format!("attr_key_{}", new_index)));
                    self.has_parse_error = false;
                    // No need to lock focus anymore
                }
           }

           if i.key_pressed(Key::Enter) && i.modifiers.is_none() { // Enter without modifiers
               log::info!("Enter pressed, attempting to generate XML and copy.");

               // Lazy initialize clipboard if it doesn't exist
               if self.clipboard.is_none() {
                   match arboard::Clipboard::new() {
                       Ok(cb) => self.clipboard = Some(cb),
                       Err(e) => {
                           log::error!("Failed to initialize clipboard: {}", e);
                           // Set error state and potentially break or show a persistent error?
                           self.has_parse_error = true;
                           // Can't proceed without clipboard, maybe return early from this closure?
                           // For now, just log and let the match below handle the None case.
                       }
                   }
               }

               match build_parsed_data(&self.input_state) {
                   Ok(parsed_data) => {
                       let generated_xml = generate_xml(&parsed_data);
                       log::info!("Generated XML:\n{}", generated_xml);

                       // Use the clipboard if it was initialized successfully
                       if let Some(clipboard) = self.clipboard.as_mut() {
                           if let Err(e) = clipboard.set_text(generated_xml.clone()) {
                               log::error!("Failed to copy to clipboard: {}", e);
                               self.has_parse_error = true;
                           } else {
                                log::info!("Copied XML to clipboard.");
                                self.has_parse_error = false;
                                // Drop the clipboard handle *before* spawning the close thread
                                drop(self.clipboard.take());
                                // Spawn a thread to send the close command (workaround for eframe <= 0.28 deadlock)
                                let ctx_clone = ctx.clone();
                                std::thread::spawn(move || {
                                    log::info!("Sending close command from separate thread.");
                                    ctx_clone.send_viewport_cmd(ViewportCommand::Close);
                                });
                                // No need to request repaint here, as we are closing
                                return; // Exit update early after spawning close thread
                           }
                       } else {
                           // This case handles if clipboard init failed earlier
                           log::error!("Clipboard not available, cannot copy.");
                           self.has_parse_error = true; // Indicate error
                       }
                   }
                   Err(e) => {
                       log::warn!("Parse error: {}", e);
                       self.has_parse_error = true;
                   }
               }
                ctx.request_repaint();
           }
       });

       // Handle escape closing immediately AFTER input processing
       if escape_pressed {
           ctx.send_viewport_cmd(ViewportCommand::Close);
           return; // Skip drawing etc.
       }

       // --- UI Drawing & Dynamic Resizing --- 
       let desired_height = egui::CentralPanel::default().show(ctx, |ui| {
           ui.heading("Tag XML Generator");
           ui.add_space(4.0);

           // Input Section
           let input_frame = egui::Frame::NONE
               .inner_margin(egui::Margin::same(5));
           let _frame_response = input_frame.show(ui, |ui| {
                // Apply red border if there was a parse error
                let stroke = if self.has_parse_error {
                   egui::Stroke::new(1.0, egui::Color32::RED)
                } else {
                    ui.visuals().widgets.inactive.bg_stroke // Default border
                };
                let rounded_frame = egui::Frame::group(ui.style())
                    .stroke(stroke)
                    .inner_margin(egui::Margin::same(10)); // Padding inside the border

                rounded_frame.show(ui, |ui| {
                   ui.label("Tag:");
                   // Use the stored ID for the tag field
                   let tag_response = ui.add(
                       egui::TextEdit::singleline(&mut self.input_state.tag)
                           .id(self.tag_field_id) // Assign the ID here
                           .hint_text("<tag_name>")
                           .desired_width(f32::INFINITY) // Take full width
                           .font(egui::TextStyle::Monospace), // Monospaced font
                   );
                   // If user interacts, clear error state
                   if tag_response.changed() || tag_response.lost_focus() {
                       self.has_parse_error = false;
                   }


                   ui.separator();
                   ui.label("Attributes (Key / Value):");

                   let mut remove_index = None;
                   let mut attribute_changed = false;
                   // Iterate through attributes, creating TextEdit widgets
                   for (i, (key, value)) in self.input_state.attributes.iter_mut().enumerate() {
                       ui.horizontal(|ui| {
                           // Key field
                            let key_response = ui.add(
                               egui::TextEdit::singleline(key)
                                   // Use Id::new for consistency
                                   .id(egui::Id::new(format!("attr_key_{}", i)))
                                   .font(egui::TextStyle::Monospace)
                                   .desired_width(ui.available_width() * 0.4)
                                   .hint_text("key"),
                           );
                            // Value field
                            let val_response = ui.add(
                               egui::TextEdit::singleline(value)
                                   // Use Id::new for consistency
                                   .id(egui::Id::new(format!("attr_val_{}", i)))
                                   .font(egui::TextStyle::Monospace)
                                   .desired_width(ui.available_width() * 0.8)
                                   .hint_text("value (empty for boolean)"),
                            );

                           // Add Remove button ("X")
                           // Use sense(Sense::click()) to potentially avoid tab focus
                           if ui.add(egui::Button::new("X").sense(egui::Sense::click())).on_hover_text("Remove attribute").clicked() {
                               remove_index = Some(i);
                               attribute_changed = true; // Mark change for error clearing
                           }

                           // Check if any attribute field changed
                           if key_response.changed() || key_response.lost_focus() || val_response.changed() || val_response.lost_focus() {
                               attribute_changed = true;
                           }
                       });
                   }

                   // Remove the attribute if the button was clicked
                   if let Some(index) = remove_index {
                       self.input_state.attributes.remove(index);
                       // No need to request redraw explicitly, egui handles it
                   }

                    // Clear error if any attribute field changed
                   if attribute_changed {
                       self.has_parse_error = false;
                   }


                   // Button to add a new attribute row - keep for manual add
                   if ui.button("+ Add Attribute").clicked() {
                       self.input_state.attributes.push((String::new(), String::new()));
                       // Focus the newly added key field?
                       let new_index = self.input_state.attributes.len() - 1;
                       ctx.memory_mut(|mem| mem.request_focus(egui::Id::new(format!("attr_key_{}", new_index))));
                       self.has_parse_error = false; // Clear error when adding
                   }

                }); // End rounded_frame
           }); // End input_frame

           // Calculate desired height based on content
           let tag_row_height = ui.text_style_height(&egui::TextStyle::Body) + ui.style().spacing.item_spacing.y;
           let attr_row_height = ui.text_style_height(&egui::TextStyle::Body) + ui.style().spacing.item_spacing.y;
           let button_height = ui.text_style_height(&egui::TextStyle::Button) + ui.style().spacing.item_spacing.y;
           let separator_height = ui.style().spacing.item_spacing.y; 
           // Use window_margin for egui 0.28.1
           let padding = ui.style().spacing.window_margin.sum().y; // Use theme margin
           
           let base_height = padding
               + ui.text_style_height(&egui::TextStyle::Heading)
               + 10.0 // space after heading
               + tag_row_height 
               + separator_height 
               + ui.text_style_height(&egui::TextStyle::Body) // "Attributes" label
               + button_height 
               + 10.0; // Space before end

           let attributes_height = self.input_state.attributes.len() as f32 * attr_row_height;
           
           // Ensure minimum height for base + ~6 attribute rows
           let min_height = base_height + (6.0 * attr_row_height);

           let calculated_height = base_height + attributes_height;
           
           // Use the calculated height but ensure it meets the minimum
           calculated_height.max(min_height)
       
       }).inner; // Get the inner result (calculated_height)

       // Resize window height if necessary, keeping width constant
       let current_size = ctx.screen_rect().size();
       let current_width = current_size.x; // Preserve current width
       // Add a small tolerance to prevent rapid resizing jitter
       if (desired_height - current_size.y).abs() > 5.0 { 
           log::debug!("Requesting height resize: current {}, desired {}", current_size.y, desired_height);
           ctx.send_viewport_cmd(ViewportCommand::InnerSize(egui::vec2(current_width, desired_height)));
       }

        // Continuously repaint while there's input focus or interaction
        if ctx.is_using_pointer() {
            ctx.request_repaint();
        }
    }

    // window_event function (removed for brevity, assumed to exist if needed for non-egui events)
    // It's often not needed if all interaction is via egui widgets.
    // Make sure any critical logic from the old window_event (like exit on close request)
    // is handled in the main loop or eframe::App::update.
}

fn main() -> Result<(), Box<dyn Error>> {
    env_logger::Builder::from_env(Env::default().default_filter_or("info,tag=info")).init();
    log::info!("Starting Tag application");

    // Determine the monitor's top-left origin via Win32 APIs
    let (origin_x, origin_y) = {
        #[cfg(target_os = "windows")]
        {
            // Get the global cursor position
            let mut pt: POINT = POINT { x: 0, y: 0 };
            unsafe { let _ = GetCursorPos(&mut pt); }
            // Find the monitor nearest to the cursor
            let hmon = unsafe { MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST) };
            // Query monitor info
            let mut mi = MONITORINFOEXW::default();
            mi.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
            unsafe { let _ = GetMonitorInfoW(hmon, &mut mi as *mut _ as *mut _); }
            (mi.monitorInfo.rcMonitor.left as f32, mi.monitorInfo.rcMonitor.top as f32)
        }
        #[cfg(not(target_os = "windows"))]
        {
            // Default to origin if not on Windows
            (0.0, 0.0)
        }
    };
    // Apply fixed offsets from the monitor origin
    let offset_x = 250.0; // swapped horizontal padding
    let offset_y = 100.0; // swapped vertical padding
    let start_x = origin_x + offset_x;
    let start_y = origin_y + offset_y;
    log::info!("Calculated initial window position: ({}, {})", start_x, start_y);

    // Configure initial window position and size
    let initial_width = 500.0; // Restore desired initial width

    let options = eframe::NativeOptions {
        viewport: ViewportBuilder::default()
            .with_inner_size([initial_width, 100.0]) // Height is placeholder, will be overridden
            .with_position([start_x, start_y]), // Set initial position relative to monitor
        ..Default::default()
    };

    eframe::run_native(
        "Tag XML Generator", // Window title
        options,
        Box::new(|cc| Ok(Box::new(App::new(cc)))), // App creation factory
    )
    .map_err(|e| Box::new(e) as Box<dyn Error>)
}
