# Tag

A simple XML tag generator with a clean UI.

## Usage

Type your tag and attributes, see the generated XML in real-time.

**Input format:**
- `tagname` → `<tagname>\n\n</tagname>`
- `tagname⭾attribute⭾value` → `<tagname attribute="value">\n\n</tagname>`
- `tagname⭾boolean⭾⭾other⭾value` → `<tagname boolean other="value">\n\n</tagname>`

**Controls:**
- `ENTER` - Close window and type the XML
- `CTRL+ENTER` - Copy XML to clipboard  
- `ESC` - Cancel and exit
- `TAB` - Add tab character

## Building

```bash
zig build                    # Debug build
zig build -Doptimize=ReleaseFast  # Release build
```

## Example

Input: `div⭾class⭾container⭾hidden⭾`  
Output: `<div class="container" hidden>\n\n</div>`

The generated XML includes an empty line between opening and closing tags for easy cursor positioning. 