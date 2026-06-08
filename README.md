# View — macOS Image Viewer

A lightweight, macOS image viewer written in Swift. 

**Why use View instead of Preview?** Unlike Apple's built-in Preview app (which requires you to manually select multiple files to browse them together), **View** automatically detects all images in the same folder , just open one image and use the arrow keys to instantly flip through the rest. It's built specifically for fast, focused image browsing without the bloat of PDF editing tools, and includes out-of-the-box support for 3D `.glb` models and `.svg` files. Also, change the background color to get better view of transparent images. 

Built with Gemini 3.5 Flash.

---

## Installation & Usage (Pre-built)

MacOS 13+ is required to run this application.
If you downloaded `View.zip` from the Releases page, macOS will flag it as "damaged" because it is not signed with a paid Apple Developer certificate. To fix this, extract the app, open your Terminal, and remove the quarantine flag:

```bash
xattr -cr /path/to/View.app
```
*(Replace `/path/to/View.app` with the actual path, e.g., `~/Downloads/View.app`)*

### Quick Start
1. **Move it** to your `/Applications` folder (optional but recommended).
2. **Open via Finder:** Double-click `View.app` — a file picker will appear.
3. **Drag and drop:** Drag any supported file onto the app icon in the Dock or Finder.
4. **Open from Terminal:**
   ```bash
   open View.app --args /path/to/image.png
   ```

### Default Viewer Setup
To make images open in View automatically:
- Right-click any image → **Get Info** (`Cmd+I`)
- Expand **Open with**
- Select **View.app** (click **Other…** if not listed)
- Click **Change All…**

Once an image is open, use the arrow keys (`←` / `→`) to instantly browse all images in the same folder.

---

## Supported Formats

| Format | Notes |
| :--- | :--- |
| PNG, JPG / JPEG | Always enabled |
| SVG | Toggle via Tools menu |
| EPS | Toggle via Tools menu |
| TIFF | Toggle via Tools menu |
| GLB (3D model) | Toggle via 3D Viewer menu — works fully offline |

---

## Keyboard Shortcuts

| Key | Action |
| :--- | :--- |
| `→` / `Space` | Next image |
| `←` / `Backspace` | Previous image |
| `R` | Rotate 90° clockwise |
| `+` / `=` | Zoom in |
| `-` | Zoom out |
| `Escape` | Reset zoom / exit fullscreen |
| `Cmd+B` / `B` | Cycle background: Dark → Black → White |
| `Cmd+C` | Copy image to clipboard |
| `Cmd+Opt+C` | Copy file path to clipboard |
| `Cmd+P` | Open in Preview |
| `Cmd+W` | Close window |
| `Cmd+Q` | Quit |

Double-click the bottom HUD bar to toggle fullscreen. Double-click the title bar to maximize.

---

## Build from Source

**Requirements:** macOS 12+, Xcode Command Line Tools

```bash
xcode-select --install   # if not already installed
```

Clone the repo, then from the project directory:

```bash
chmod +x build.sh
./build.sh
```

Output: `View.app` in the same directory.

**Source files needed to build:**

```
main.swift            ← entire app source
build.sh              ← build script
model-viewer.min.js   ← bundled for offline GLB support
app_icon.png          ← optional custom icon
```

The bundled `model-viewer.min.js` is automatically copied into the app — GLB 3D viewing works fully offline with no network requests.



## Features

- **Folder browsing** — arrow keys navigate all images in the current directory
- **Smart memory cache** — only 3 images in RAM at a time (prev / current / next), background preloading, instant eviction
- **Smooth zoom** — native trackpad pinch-to-zoom via `NSScrollView`
- **HUD overlay** — bar showing filename, dimensions, file size, and position (e.g. `12 of 340`)
- **Background modes** — Dark, Black, White
- **Rotation** — in-memory 90° rotation without modifying the file
- **3D model viewer** — GLB files rendered via `model-viewer`, fully offline
- **Multi-window** — open multiple files, each in its own window; Dock menu lists all open windows

