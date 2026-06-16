# View

A fast file viewer for macOS.

Open image and pdf files and browse the entire folder with arrow keys.

## Why View?

macOS Preview requires you to select every file you want to browse. View takes a different approach: open a single file, and the entire directory is at your fingertips. Navigate with arrow keys, trash what you don't need, rename on the fly, all without leaving the keyboard.

View is designed for fast browsing and file management, it is not a replacement for Apple Preview. For editing, markup, or annotations, you can quickly hand off the current file to Preview by pressing `Cmd+P`.

---

## Installation

**Requirements:** macOS 12+ (Monterey or later), Apple Silicon

### From Releases

Download `View.zip` from the [Releases](https://github.com/pratiman-de/view/releases/tag/v1.0.0) page. Since the app is not notarized with an Apple Developer certificate, you will need to remove the quarantine flag before launching:

```bash
xattr -cr /path/to/View.app
```

Then move `View.app` to `/Applications` or run it from any location.

### Set as Default Viewer

Right-click any image → **Get Info** → **Open with** → select `View.app` → **Change All…**

---

## Usage

| Action | Input |
| :--- | :--- |
| Open file picker | Launch app directly |
| Open specific file | `open View.app --args /path/to/image.png` |
| Open via Finder | Double-click any associated file |
| Open via Dock | Drag files onto the app icon |

Once an image is open, all supported files in the same directory are available for browsing.

### Keyboard Shortcuts

| Key | Action |
| :--- | :--- |
| `→` / `Space` | Next image |
| `←` / `Backspace` | Previous image |
| `R` | Rotate 90° clockwise |
| `+` / `-` | Zoom in / out |
| `Escape` | Reset zoom / exit fullscreen |
| `B` | Cycle background (Dark → Black → White) |
| `Cmd+Delete` | Move file to Trash |
| `Cmd+R` | Rename file |
| `Cmd+C` | Copy image to clipboard |
| `Cmd+Opt+C` | Copy file path to clipboard |
| `Cmd+P` | Open in Preview |

Double-click the title bar to maximize. Double-click the HUD bar to toggle fill-screen.

---

## Supported Formats

All formats can be independently enabled or disabled at compile time via `build_config.sh`.

| Format | Extensions | Default |
| :--- | :--- | :--- |
| PNG | `.png` | Enabled |
| JPEG | `.jpg`, `.jpeg` | Enabled |
| SVG | `.svg` | Enabled |
| EPS | `.eps` | Disabled |
| TIFF | `.tif`, `.tiff` | Enabled |
| PDF | `.pdf` | Enabled |
| GLB (3D) | `.glb` | Disabled |

Formats can also be toggled at runtime from the **Tools → File Types** menu.

---

## Build from Source

**Requirements:** macOS 12+, Xcode Command Line Tools

```bash
xcode-select --install   # if not already installed
git clone https://github.com/pratiman-de/view.git
cd view
chmod +x build.sh
./build.sh
```

The build produces `View.app` in the project directory. No Xcode project is required.

### Build Configuration

Edit `build_config.sh` to enable or disable features before building:

```bash
# File Types
ENABLE_PNG=1
ENABLE_JPG=1
ENABLE_SVG=1
ENABLE_EPS=0
ENABLE_TIFF=1
ENABLE_GLB=0
ENABLE_PDF=1

# Edit Features
ENABLE_TRASH=1
ENABLE_RENAME=1
```

---

## Features

- **Folder browsing** — arrow keys navigate all images in the current directory
- **Smart memory cache** — only 3 images in RAM at a time (prev / current / next), background preloading, instant eviction
- **Smooth zoom** — native trackpad pinch-to-zoom via NSScrollView
- **HUD overlay** — bar showing filename, dimensions, file size, and position (e.g. 12 of 340)
- **Background modes** — Dark, Black, White
- **Rotation** — in-memory 90° rotation without modifying the file
- **3D model viewer** — GLB files rendered via model-viewer, fully offline
- **Multi-window** — open multiple files, each in its own window; Dock menu lists all open windows
