# Tag - XML Generator UI

A fast, lightweight Windows application for generating XML tags with attributes through a simple text interface.

## Features

- **Real-time XML generation** - Type and see XML output instantly
- **Intuitive syntax** - Use tabs to separate tag names, attributes, and values
- **Two output modes**:
  - **Type mode** (ENTER) - Types XML directly into any application with reliable Shift+Enter line breaks
  - **Clipboard mode** (CTRL+ENTER or SHIFT+ENTER) - Copies XML to clipboard
- **Smart attribute handling** - Automatically detects boolean vs key-value attributes
- **Multi-monitor support** - Opens on the monitor where your mouse cursor is located
- **Clean, modern UI** - Built with Sokol graphics library

## Quick Start

1. Run `tag.exe`
2. Type your tag structure using tabs to separate elements
3. Press ENTER to type the XML or CTRL+ENTER to copy to clipboard

## Examples

### Simple tag
**Input:**
```
div
```
**Output:**
```xml
<div>

</div>
```

### Tag with attributes
**Input:**
```
img<tab>src<tab>photo.jpg<tab>alt<tab>A photo
```
**Output:**
```xml
<img src="photo.jpg" alt="A photo">

</img>
```

### Mixed boolean and key-value attributes
**Input:**
```
button<tab>disabled<tab><tab>type<tab>submit
```
**Output:**
```xml
<button disabled type="submit">

</button>
```

## Controls

- **Type characters** - Build your tag structure
- **TAB** - Add tab character (separates tag name, attributes, values)
- **ENTER** - Close app and type XML with reliable line breaks
- **CTRL+ENTER** or **SHIFT+ENTER** - Copy XML to clipboard and quit
- **ESC** - Cancel and quit immediately
- **BACKSPACE** - Delete last character

## Building

### Prerequisites
- [Zig](https://ziglang.org/) (latest)

### Build Commands
```bash
# Debug build (shows console logs)
zig build

# Release build (no console window)
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Run directly
zig build run
```

## Acknowledgments

**Special thanks to [SUI (Simple User Input)](https://github.com/Finxx1/SUI)** - This project relies on the excellent SUI library by Finxx1 for reliable keyboard input simulation on Windows. SUI provides the robust foundation that makes the typing functionality work seamlessly across different applications.

## Technical Details

- **Language**: Zig
- **Graphics**: [Sokol](https://github.com/floooh/sokol) 
- **Input Simulation**: [SUI](https://github.com/Finxx1/SUI) by Finxx1
- **Platform**: Windows (input simulation is Windows-specific)
- **Architecture**: Single executable, no external dependencies

## License

MIT License - see [LICENSE](LICENSE) file for details. 