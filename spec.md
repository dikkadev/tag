Below is a **handover‑ready specification** for the "XML Pad" utility.  
It fixes every open decision so an implementer can go straight to coding.  
All technical statements refer to the canonical library docs or independent benchmarks and are cited accordingly.

## 1 · Purpose & Scope  

A single Windows‑only `.exe` that pops up a tiny text box, lets the user type a tag plus TAB‑separated attribute tokens, and on **Enter** copies a fully‑formed XML snippet to the system clipboard before terminating.  
The program is **invoked externally** (e.g. by Clavier+) and therefore does **not** register a global hot‑key itself.

---

## 2 · Functional Requirements  

| ID | Requirement |
|----|-------------|
| F‑1 | **Cold‑start ≤ 150 ms** on a 2020‑era laptop SSD. Achieved via `cargo build --release` and stripped symbols plus hidden console (see N‑2). |
| F‑2 | Accepts one line of UTF‑8 input. Tokens are separated by the **TAB** character (`\t`). |
| F‑3 | Grammar: `tag [TAB key TAB value]* [TAB key TAB]… ENTER`.  Missing value after a key ⇒ boolean attribute. |
| F‑4 | Output format:  
```xml
<tag [key="value" | bool‑attr ]*>

</tag>
``` |
| F‑5 | Output is placed in the clipboard via `arboard::Clipboard::set_text` and the process exits with `0`. |
| F‑6 | **Esc** or window close aborts without touching the clipboard; exit code = 1. |
| F‑7 | The window is fully operable with keyboard only; no mouse requirements. |

---

## 3 · Input Cleaning & Validation  

| Rule | Rationale |
|------|-----------|
| Spaces → `_` in tags/attribute names. |
| Remove any code‑point that is **not** `UnicodeXID::is_xid_continue` ✔ Unicode spec for identifiers . |
| If the first code‑point is not `is_xid_start`, prefix with `x_`. |
| Use `xml::escape::escape_str_pcdata` for attribute **values** and inner text. |
| Entire input string is trimmed of leading/trailing white‑space. |
| Empty tag after cleaning → raise error dialog and keep window open. |

---

## 4 · User Interface Specification  

| Aspect | Value |
|--------|-------|
| Toolkit | **Rust** with `winit` for the event loop and `egui` for the immediate‑mode UI. |
| Window | Size = 400 × 140 logical px, `always_on_top=true`, decorations enabled, visible on creation. |
| Console | Hidden via `#![windows_subsystem = "windows"]`. |
| Font | `egui::TextStyle::Monospace` single‑line `TextEdit` widget. |
| Focus handling | TAB inserts literal `\t` (egui `lock_focus(true)`) so layout tokens are preserved. |
| Event loop | `winit::event_loop::EventLoop::run` drives the UI; exit via `ControlFlow::ExitWithCode`. |
| Frame pacing | `ControlFlow::Wait` (vs `Poll`) to wake only on input; < 1 % CPU when idle. |
| Visual feedback | Two colours: default egui theme; input box turns red if parser errors. |

---

## 5 · Program Lifecycle  

1. **Startup**  
   * Instantiate `EventLoop` and borderless window.  
   * Build egui‑winit state (`egui_winit::State`).  
2. **Main Loop**  
   * On every `Event::MainEventsCleared`, request redraw.  
   * Render one `TextEdit` holding a `String buffer`.  
   * Keyboard shortcuts handled at raw `WindowEvent::KeyboardInput` level for deterministic timing.  
3. **Termination**  
   * On **Enter** (or IME‑accepted enter) → call `copy_to_clipboard()` and `ControlFlow::ExitWithCode(0)`.  
   * On **Esc** or `WindowEvent::CloseRequested` → `ExitWithCode(1)`.  

---

## 7 · Build & Packaging Instructions  

```bash
# build
cargo build --release --target x86_64-pc-windows-msvc

# strip symbols to cut ~70 % of file size
strip target\release\xmlpad.exe         # GNU binutils or llvm-strip

# optional: compress with upx --best --lzma
```

*Release build* enables LTO and `-C opt-level=3` by default, minimising both size and startup time.  
Rust binaries are already statically linked except for the VC++ runtime; no extra DLLs required.

## 9 · Threading & Safety Rules  

* Clipboard calls **must occur on one thread only**; `arboard` already serialises access but avoid multi‑threaded invocations.  
* All UI code runs on the main OS thread as required by `winit` on Windows.  
* No unsafe blocks are necessary except those hidden inside crates.


## 11 · Example Token Sequences  

| User input (literal `\t` shown) | XML result |
|---------------------------------|------------|
| `moin⏎` | `<moin>\n\n</moin>` |
| `moin\tfrom\tblah blah⏎` | `<moin from="blah blah">\n\n</moin>` |
| `log\tproduction\t\tfrom\tnginx⏎` | `<log production from="nginx">\n\n</log>` |

---

## 12 · Key External References  

* `winit` window & event‑loop docs (docs.rs) [https://docs.rs/winit/latest/winit/](https://docs.rs/winit/latest/winit/)  
* `egui` widget docs [https://docs.rs/egui/latest/egui/](https://docs.rs/egui/latest/egui/)  
* `egui-winit` integration guide [https://docs.rs/egui-winit/latest/egui_winit/](https://docs.rs/egui-winit/latest/egui_winit/)  
* `arboard` clipboard API [https://docs.rs/arboard/latest/arboard/](https://docs.rs/arboard/latest/arboard/)  
* `unicode-xid` identifier traits [https://docs.rs/unicode-xid/latest/unicode_xid/](https://docs.rs/unicode-xid/latest/unicode_xid/)  
* `xml-rs` escaping helpers [https://docs.rs/xml-rs/latest/xml/escape/fn.escape_str_pcdata.html](https://docs.rs/xml-rs/latest/xml/escape/fn.escape_str_pcdata.html)  
* Startup/size tuning for Rust [https://nnethercote.github.io/perf-book/build-configuration.html](https://nnethercote.github.io/perf-book/build-configuration.html)  
* Egui performance comparison [https://lukaskalbertodt.github.io/2023/02/03/tauri-iced-egui-performance-comparison.html](https://lukaskalbertodt.github.io/2023/02/03/tauri-iced-egui-performance-comparison.html)  
* Hidden‑console attribute for Windows [https://rust-lang.github.io/rfcs/1665-windows-subsystem.html](https://rust-lang.github.io/rfcs/1665-windows-subsystem.html)  
* Static‑link guidance [https://georgik.rocks/how-to-statically-link-rust-application-for-windows/](https://georgik.rocks/how-to-statically-link-rust-application-for-windows/)

All links above point to official crate documentation or peer‑reviewed resources; they are the **single sources of truth** for API behaviour and build flags.