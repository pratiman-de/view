import Cocoa
import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

// Returns the list of file extensions enabled at compile time.
func supportedExtensions() -> [String] {
    var exts: [String] = []
#if ENABLE_PNG
    exts.append("png")
#endif
#if ENABLE_JPG
    exts.append(contentsOf: ["jpg", "jpeg"])
#endif
#if ENABLE_SVG
    exts.append("svg")
#endif
#if ENABLE_EPS
    exts.append("eps")
#endif
#if ENABLE_TIFF
    exts.append(contentsOf: ["tif", "tiff"])
#endif
#if ENABLE_GLB
    exts.append("glb")
#endif
#if ENABLE_PDF
    exts.append("pdf")
#endif
    return exts
}

// Custom ClipView that centers the document view (the image) when it's smaller than the scroll view bounds.
class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let docView = documentView else { return rect }
        
        let clipBounds = self.bounds
        let docFrame = docView.frame
        
        // Center horizontally if document is narrower than clip view
        if docFrame.width < clipBounds.width {
            rect.origin.x = docFrame.origin.x - (clipBounds.width - docFrame.width) / 2.0
        }
        
        // Center vertically if document is shorter than clip view (shift up slightly for HUD offset)
        if docFrame.height < clipBounds.height {
            let mag = self.enclosingScrollView?.magnification ?? 1.0
            let desiredOffset = mag > 0 ? 17.5 / mag : 17.5
            let maxOffset = (clipBounds.height - docFrame.height) / 2.0
            let offset = min(desiredOffset, maxOffset)
            rect.origin.y = docFrame.origin.y - (clipBounds.height - docFrame.height) / 2.0 - offset
        }
        
        return rect
    }
}

class ImageViewController: NSViewController, WKNavigationDelegate, NSMenuItemValidation {
    
    var scrollView: NSScrollView!
    var imageView: NSImageView!
    var webView: WKWebView!
    var hudView: NSVisualEffectView!
    var hudLabel: NSTextField!
    
    // File list management
    var imageURLs: [URL] = []
    var currentIndex: Int = -1
    var lastNavigationDirection: Int = 1 // 1 for forward, -1 for backward
    
    // Dynamic extensions support
    var activeExtensions: Set<String> = {
        var exts = Set<String>()
#if ENABLE_PNG
        exts.insert("png")
#endif
#if ENABLE_JPG
        exts.insert("jpg")
        exts.insert("jpeg")
#endif
        return exts
    }()
    
    var preloadedImages: [URL: NSImage] = [:]
    
    var keyDownMonitor: Any?
    
    var hasPerformedInitialZoom = false
    
    override func loadView() {
        // Create the main container view
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.autoresizingMask = [.width, .height]
        self.view = container
        
        // Create scroll view
        scrollView = NSScrollView(frame: container.bounds)
        scrollView.autoresizingMask = [.width, .height]
        if #available(macOS 11.0, *) {
            scrollView.automaticallyAdjustsContentInsets = false
        }
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay   // scrollers float over content, never steal clip view space
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 40.0
        scrollView.drawsBackground = false
        
        // Use centering clip view
        let clipView = CenteringClipView(frame: scrollView.bounds)
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        
        // Create image view
        imageView = NSImageView(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        scrollView.documentView = imageView
        
        container.addSubview(scrollView)
        
        // Create web view
        let webConfig = WKWebViewConfiguration()
        // Allow file:// pages to load sibling file:// resources (needed for model-viewer.min.js)
        webConfig.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        webView = WKWebView(frame: container.bounds, configuration: webConfig)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.isHidden = true
        container.addSubview(webView)
        
        // Create translucent HUD Overlay
        setupHUD(in: container)
    }
    
    private func setupHUD(in container: NSView) {
        hudView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: container.bounds.width, height: 35))
        hudView.autoresizingMask = [.width, .none]
        hudView.material = .hudWindow
        hudView.state = .active
        hudView.blendingMode = .withinWindow
        
        hudLabel = NSTextField(frame: NSRect(x: 10, y: 5, width: container.bounds.width - 20, height: 25))
        hudLabel.autoresizingMask = [.width, .height]
        hudLabel.isBezeled = false
        hudLabel.drawsBackground = false
        hudLabel.isEditable = false
        hudLabel.isSelectable = false
        hudLabel.alignment = .center
        hudLabel.textColor = .white
        hudLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        hudLabel.stringValue = "No image loaded"
        
        hudView.addSubview(hudLabel)
        container.addSubview(hudView)
        
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleHUDDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        hudView.addGestureRecognizer(doubleClick)
    }
    
    @objc func handleHUDDoubleClick(_ sender: NSClickGestureRecognizer) {
        if let window = self.view.window as? ViewWindow {
            window.toggleFillScreen()
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set up global keystroke monitors
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard self.view.window?.isKeyWindow == true else { return event }
            if self.handleKeyDown(with: event) == true {
                return nil // consume event
            }
            return event
        }
    }
    
    deinit {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    override func viewDidLayout() {
        super.viewDidLayout()
        // Reposition HUD at the bottom of the view
        hudView.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: 35)
        
        if !hasPerformedInitialZoom {
            hasPerformedInitialZoom = true
            DispatchQueue.main.async { [weak self] in
                if self?.imageView.image != nil {
                    self?.zoomToFit()
                }
            }
        }
    }
    
    // Load directory of files and focus on selected target
    func loadDirectory(focusingOn targetURL: URL, resetZoom: Bool = true, autoEnableFormat: Bool = false) {
        // Auto-enable format support if opening a file of a currently disabled format
        if autoEnableFormat {
            let ext = targetURL.pathExtension.lowercased()
            let toggleableExtensions = supportedExtensions()
            if toggleableExtensions.contains(ext) && !activeExtensions.contains(ext) {
                activeExtensions.insert(ext)
                if ext == "tif" || ext == "tiff" {
                    activeExtensions.insert("tif")
                    activeExtensions.insert("tiff")
                }
            }
        }
        
        let dirURL = targetURL.deletingLastPathComponent()
        let fm = FileManager.default
        
        do {
            let files = try fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            
            // Filter using dynamic activeExtensions
            var images = files.filter { activeExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            
            // Keep the target URL in the traversal list even if its file type is unchecked
            if !images.contains(targetURL.standardized) {
                images.append(targetURL.standardized)
                images.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
            
            self.imageURLs = images
            
            if let index = images.firstIndex(of: targetURL.standardized) {
                self.currentIndex = index
            } else {
                self.currentIndex = 0
            }
            
            displayCurrentImage(resetZoom: resetZoom)
            
        } catch {
            // Fallback: load only the targeted image if folder scanning fails due to permissions/sandbox
            self.imageURLs = [targetURL.standardized]
            self.currentIndex = 0
            displayCurrentImage(resetZoom: resetZoom)
        }
    }
    
    func displayCurrentImage(resetZoom: Bool = false) {
        guard currentIndex >= 0, currentIndex < imageURLs.count else {
            hudLabel.stringValue = "No supported images in folder"
            return
        }
        
        let url = imageURLs[currentIndex]
        let ext = url.pathExtension.lowercased()
        

        
#if ENABLE_GLB
        if ext == "glb" {
            scrollView.isHidden = true
            webView.isHidden = false
            
            guard let data = try? Data(contentsOf: url) else {
                showError("Could not read GLB file: \(url.lastPathComponent)")
                return
            }
            let base64 = data.base64EncodedString()
            
            let colorHex = backgroundMode == .dark ? "#171717" : (backgroundMode == .black ? "#000000" : "#ffffff")
            
            // Resolve the bundled model-viewer.min.js from the app Resources directory
            let resourcesURL = Bundle.main.resourceURL ?? url.deletingLastPathComponent()
            
            let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <style>
                    body, html { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background-color: \(colorHex); }
                    model-viewer { width: 100%; height: 100%; background-color: \(colorHex); --poster-color: transparent; }
                </style>
                <script type="module" src="model-viewer.min.js"></script>
            </head>
            <body>
                <model-viewer id="viewer" camera-controls auto-rotate shadow-intensity="1"></model-viewer>
                <script>
                    window.addEventListener('load', () => {
                        const base64Data = "\(base64)";
                        const byteCharacters = atob(base64Data);
                        const byteNumbers = new Array(byteCharacters.length);
                        for (let i = 0; i < byteCharacters.length; i++) {
                            byteNumbers[i] = byteCharacters.charCodeAt(i);
                        }
                        const byteArray = new Uint8Array(byteNumbers);
                        const blob = new Blob([byteArray], {type: "model/gltf-binary"});
                        const objectURL = URL.createObjectURL(blob);
                        
                        const viewer = document.getElementById("viewer");
                        viewer.src = objectURL;
                    });
                </script>
            </body>
            </html>
            """
            
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ViewApp_GLB")
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let tmpHTML = tmpDir.appendingPathComponent("glb_viewer.html")
            let tmpJS   = tmpDir.appendingPathComponent("model-viewer.min.js")
            
            if !FileManager.default.fileExists(atPath: tmpJS.path) {
                let srcJS = resourcesURL.appendingPathComponent("model-viewer.min.js")
                try? FileManager.default.copyItem(at: srcJS, to: tmpJS)
            }
            
            if (try? html.write(to: tmpHTML, atomically: true, encoding: .utf8)) != nil {
                webView.loadFileURL(tmpHTML, allowingReadAccessTo: tmpDir)
            } else {
                showError("Could not write GLB viewer HTML to temp directory")
            }
            
            updateHUDForGLB(with: url)
            manageMemoryCache()
            return
        }
#endif
        
        scrollView.isHidden = false
        webView.isHidden = true
        
        // Get image from cache or load it
        var image: NSImage? = preloadedImages[url]
        if image == nil {
            if ext == "svg" || ext == "pdf" {
                // NSImage handles SVG and PDF natively on macOS; bypass CGImageSource (raster only)
                image = NSImage(contentsOf: url)
            } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                let img = NSImage(cgImage: cgImage, size: .zero)
                image = img
                preloadedImages[url] = img
            }
        }
        
        guard let currentImg = image else {
            showError("Could not load image: \(url.lastPathComponent)")
            return
        }
        
        // Set image and scale viewport
        imageView.image = currentImg
        imageView.frame = NSRect(origin: .zero, size: currentImg.size)
        
        if resetZoom {
            zoomToFit()
        }
        
        updateHUD(with: url, image: currentImg)
        
        // Manage memory: preload neighbors, release far images
        manageMemoryCache()
    }
    
    func zoomToFit() {
        guard let img = imageView.image else { return }
        // Use scroll view content size (unmagnified visible viewport area)
        let scrollSize = scrollView.contentSize
        let imgSize = img.size
        
        if imgSize.width <= 0 || imgSize.height <= 0 { return }
        
        // Add padding around the image (60px width padding, 100px height padding to clear HUD and titlebar)
        let paddingX: CGFloat = 60.0
        let paddingY: CGFloat = 100.0
        
        let targetWidth = max(scrollSize.width - paddingX, 20.0)
        let targetHeight = max(scrollSize.height - paddingY, 20.0)
        
        let wRatio = targetWidth / imgSize.width
        let hRatio = targetHeight / imgSize.height
        let scale = min(wRatio, hRatio)
        
        let finalScale = scale > 0.05 ? scale : 0.05
        
        // Zoom-out floor = fit-to-window scale. User can zoom in freely and zoom
        // back out to fit, but no further. Updates on every window resize automatically.
        scrollView.minMagnification = finalScale
        scrollView.magnification = finalScale
        
        // Center view in scrollview content bounds (HUD offset is handled by CenteringClipView)
        let docFrame = imageView.frame
        let bounds = scrollView.contentView.bounds
        let x = (docFrame.width - bounds.width) / 2.0
        let y = (docFrame.height - bounds.height) / 2.0
        scrollView.contentView.scroll(to: NSPoint(x: x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    
    func rotateCurrentImage() {
        guard currentIndex >= 0, currentIndex < imageURLs.count else { return }
        let url = imageURLs[currentIndex]
        guard let image = imageView.image else { return }
        
        let size = image.size
        let rotatedSize = NSSize(width: size.height, height: size.width)
        let rotatedImage = NSImage(size: rotatedSize)
        
        rotatedImage.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: rotatedSize.width / 2, yBy: rotatedSize.height / 2)
        transform.rotate(byDegrees: -90.0) // Rotate 90 degrees clockwise
        transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
        transform.concat()
        
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        rotatedImage.unlockFocus()
        
        // Update cached image and UI
        preloadedImages[url] = rotatedImage
        imageView.image = rotatedImage
        imageView.frame = NSRect(origin: .zero, size: rotatedSize)
        zoomToFit()
        
        updateHUD(with: url, image: rotatedImage)
    }
    
#if ENABLE_TRASH
    func trashCurrentImage() {
        guard currentIndex >= 0, currentIndex < imageURLs.count else { return }
        let url = imageURLs[currentIndex]
        
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            
            self.imageURLs.remove(at: self.currentIndex)
            if self.imageURLs.isEmpty {
                self.hudLabel.stringValue = "No supported images in folder"
                self.imageView.image = nil
                if let web = self.webView { web.isHidden = true }
                self.scrollView.isHidden = true
            } else {
                if self.lastNavigationDirection == -1 {
                    self.currentIndex -= 1
                    if self.currentIndex < 0 {
                        self.currentIndex = 0
                    }
                } else {
                    if self.currentIndex >= self.imageURLs.count {
                        self.currentIndex = self.imageURLs.count - 1
                    }
                }
                self.displayCurrentImage(resetZoom: false)
            }
        } catch {
            showError("Could not move file to Trash: \(error.localizedDescription)")
        }
    }
#endif

#if ENABLE_RENAME
    func renameCurrentImage() {
        guard currentIndex >= 0, currentIndex < imageURLs.count else { return }
        let currentURL = imageURLs[currentIndex]
        
        let alert = NSAlert()
        alert.messageText = "Rename File"
        alert.informativeText = ""
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = currentURL.deletingPathExtension().lastPathComponent
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            guard !newName.isEmpty else { return }
            
            var targetURL = currentURL.deletingLastPathComponent().appendingPathComponent("\(newName).\(currentURL.pathExtension)")
            guard targetURL != currentURL else { return }
            
            if FileManager.default.fileExists(atPath: targetURL.path) {
                let overwriteAlert = NSAlert()
                overwriteAlert.messageText = "File already exists"
                overwriteAlert.informativeText = "A file named \"\(targetURL.lastPathComponent)\" already exists. Do you want to overwrite it or keep both?"
                overwriteAlert.addButton(withTitle: "Keep Both")
                overwriteAlert.addButton(withTitle: "Overwrite")
                overwriteAlert.addButton(withTitle: "Cancel")
                
                let response = overwriteAlert.runModal()
                if response == .alertFirstButtonReturn {
                    var copyIndex = 1
                    while FileManager.default.fileExists(atPath: targetURL.path) {
                        targetURL = currentURL.deletingLastPathComponent().appendingPathComponent("\(newName) (\(copyIndex)).\(currentURL.pathExtension)")
                        copyIndex += 1
                    }
                } else if response == .alertSecondButtonReturn {
                    do {
                        try FileManager.default.trashItem(at: targetURL, resultingItemURL: nil)
                    } catch {
                        self.showError("Failed to remove existing file: \(error.localizedDescription)")
                        return
                    }
                } else {
                    return
                }
            }
            
            do {
                try FileManager.default.moveItem(at: currentURL, to: targetURL)
                self.imageURLs[self.currentIndex] = targetURL
                self.displayCurrentImage(resetZoom: false)
            } catch {
                self.showError("Failed to rename file: \(error.localizedDescription)")
            }
        }
    }
#endif
    
    // Smart Memory Management: Dynamic active-window cache (K=3)
    private func manageMemoryCache() {
        guard currentIndex >= 0, currentIndex < imageURLs.count else { return }
        
        let currentURL = imageURLs[currentIndex]
        let prevURL = currentIndex > 0 ? imageURLs[currentIndex - 1] : nil
        let nextURL = currentIndex < imageURLs.count - 1 ? imageURLs[currentIndex + 1] : nil
        
        let activeURLs = [currentURL, prevURL, nextURL].compactMap { $0 }
        
        // 1. Evict any loaded image URLs that are not part of the active 3-image window
        let cachedURLs = Array(preloadedImages.keys)
        for url in cachedURLs {
            if !activeURLs.contains(url) {
                preloadedImages.removeValue(forKey: url) // Releases NSImage, freeing memory instantly
            }
        }
        
        // 2. Preload neighbors in background thread to avoid stutter on transition
        // Skip glb (rendered via WebKit) and svg (loaded via NSImage, not CGImageSource)
        let nonRasterExts = ["glb", "svg"]
        let urlsToPreload = [prevURL, nextURL].compactMap { $0 }.filter { preloadedImages[$0] == nil && !nonRasterExts.contains($0.pathExtension.lowercased()) }
        
        DispatchQueue.global(qos: .userInitiated).async {
            for url in urlsToPreload {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    
                    DispatchQueue.main.async { [weak self] in
                        let img = NSImage(cgImage: cgImage, size: .zero)
                        
                        // Double check we are still hovering near it
                        guard let self = self else { return }
                        let currentActive = [
                            self.currentIndex > 0 ? self.imageURLs[self.currentIndex - 1] : nil,
                            self.currentIndex < self.imageURLs.count - 1 ? self.imageURLs[self.currentIndex + 1] : nil
                        ].compactMap { $0 }
                        
                        if currentActive.contains(url) {
                            self.preloadedImages[url] = img
                        }
                    }
                }
            }
        }
    }
    
    private func updateHUD(with url: URL, image: NSImage) {
        let filename = url.lastPathComponent
        let dimensions = "\(Int(image.size.width)) × \(Int(image.size.height))"
        
        var fileSizeString = "Unknown size"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useAll]
            formatter.countStyle = .file
            fileSizeString = formatter.string(fromByteCount: Int64(size))
        }
        
        let progress = "\(currentIndex + 1) of \(imageURLs.count)"
        
        hudLabel.stringValue = "\(filename)   |   \(dimensions)   |   \(fileSizeString)   |   \(progress)"
        
        // Set window title
        if let window = view.window {
            window.title = "\(filename) (\(progress))"
        }
    }
    
    private func showError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    // Key event dispatcher
    func handleKeyDown(with event: NSEvent) -> Bool {
        // Handle Command shortcuts first
        if event.modifierFlags.contains(.command) {
#if ENABLE_TRASH
            if event.keyCode == 51 || event.keyCode == 117 { // Delete/Backspace key or Forward Delete
                trashCurrentImage()
                return true
            }
#endif
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                switch chars {
                case "q":
                    NSApplication.shared.terminate(nil)
                    return true
                case "w":
                    self.view.window?.performClose(nil)
                    return true
                case "c":
                    if event.modifierFlags.contains(.option) {
                        copyPathToClipboard()
                    } else {
                        copyImageToClipboard()
                    }
                    return true
                case "b":
                    cycleBackground()
                    return true
                case "r":
                    if event.modifierFlags.contains(.command) {
#if ENABLE_RENAME
                        renameCurrentImage()
                        return true
#endif
                    }
                case "p":
                    openInPreview()
                    return true
                default:
                    break
                }
            }
        }
        
        // Key codes or characters
        switch event.keyCode {
        case 124, 49: // Right Arrow, Spacebar
            // Next image
            if currentIndex < imageURLs.count - 1 {
                lastNavigationDirection = 1
                currentIndex += 1
                displayCurrentImage(resetZoom: true)
            }
            return true
            
        case 123, 51: // Left Arrow, Delete/Backspace
            // Previous image
            if currentIndex > 0 {
                lastNavigationDirection = -1
                currentIndex -= 1
                displayCurrentImage(resetZoom: true)
            }
            return true
            
        case 15: // 'R' key (Rotate 90 degrees)
            rotateCurrentImage()
            return true
            
        case 53: // Escape key (exit fullscreen / restore window / reset zoom)
            if let window = view.window {
                if window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                } else {
                    if let screen = window.screen {
                        let visibleFrame = screen.visibleFrame
                        let isMaximized = abs(window.frame.width - visibleFrame.width) < 5 && abs(window.frame.height - visibleFrame.height) < 5
                        if isMaximized {
                            if let viewWindow = window as? ViewWindow {
                                viewWindow.toggleFillScreen()
                            }
                        } else {
                            zoomToFit()
                        }
                    } else {
                        zoomToFit()
                    }
                }
            } else {
                zoomToFit()
            }
            return true
            
        case 24, 69: // '+' key or '=' key
            scrollView.magnification = min(scrollView.magnification * 1.25, scrollView.maxMagnification)
            return true
            
        case 27, 78: // '-' key
            scrollView.magnification = max(scrollView.magnification * 0.8, scrollView.minMagnification)
            return true
            
        case 11: // 'B' key (Cycle background)
            cycleBackground()
            return true
            
        default:
            break
        }
        
        // Match by characters if any
        if let chars = event.charactersIgnoringModifiers {
            switch chars.lowercased() {
            case "r":
                rotateCurrentImage()
                return true
            case "b":
                cycleBackground()
                return true
            default:
                break
            }
        }
        
        return false
    }
    
    @objc func copyImageToClipboard() {
        guard currentIndex >= 0, currentIndex < imageURLs.count else { return }
        guard let img = imageView.image else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([img])
        
        // Temporarily overlay "Copied to clipboard!" on HUD
        let originalHUDText = hudLabel.stringValue
        hudLabel.stringValue = "Copied to clipboard!"
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.hudLabel.stringValue == "Copied to clipboard!" {
                self?.hudLabel.stringValue = originalHUDText
            }
        }
    }
    
    @objc func copyPathToClipboard() {
        guard currentIndex >= 0, currentIndex < imageURLs.count else { return }
        let url = imageURLs[currentIndex]
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(url.path, forType: .string)
        
        // Temporarily overlay "Path copied to clipboard!" on HUD
        let originalHUDText = hudLabel.stringValue
        hudLabel.stringValue = "Path copied to clipboard!"
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.hudLabel.stringValue == "Path copied to clipboard!" {
                self?.hudLabel.stringValue = originalHUDText
            }
        }
    }
    
    @objc func openInPreview() {
        guard currentIndex >= 0, currentIndex < imageURLs.count else { return }
        let url = imageURLs[currentIndex]
        
        let workspace = NSWorkspace.shared
        if let previewURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.open([url], withApplicationAt: previewURL, configuration: configuration, completionHandler: nil)
        } else {
            workspace.open(url)
        }
    }
    
    func promptForFile() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose an Image"
        let extensions = supportedExtensions()
        openPanel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        
        openPanel.beginSheetModal(for: self.view.window!) { [weak self] response in
            if response == .OK, let url = openPanel.url {
                self?.loadDirectory(focusingOn: url, autoEnableFormat: true)
            } else {
                if self?.imageURLs.isEmpty == true {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
    
    // Background toggling options
    enum BackgroundMode {
        case dark, black, white
    }
    var backgroundMode: BackgroundMode = .dark
    
    func changeBackground(to color: NSColor) {
        self.view.window?.backgroundColor = color
        
        // Also update WebView background if active
        if let web = webView, !web.isHidden {
            var colorHex = "#171717"
            if color == .black { colorHex = "#000000" }
            else if color == .white { colorHex = "#ffffff" }
            let js = "document.body.style.backgroundColor = '\(colorHex)'; document.getElementById('viewer').style.backgroundColor = '\(colorHex)';"
            web.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    @objc func setBackgroundDark() {
        backgroundMode = .dark
        changeBackground(to: NSColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1.0))
        refreshHUD()
    }
    
    @objc func setBackgroundBlack() {
        backgroundMode = .black
        changeBackground(to: .black)
        refreshHUD()
    }
    
    @objc func setBackgroundWhite() {
        backgroundMode = .white
        changeBackground(to: .white)
        refreshHUD()
    }
    
    @objc func cycleBackground() {
        switch backgroundMode {
        case .dark:
            setBackgroundBlack()
        case .black:
            setBackgroundWhite()
        case .white:
            setBackgroundDark()
        }
    }
    
    func refreshHUD() {
        if currentIndex >= 0, currentIndex < imageURLs.count {
            let url = imageURLs[currentIndex]
            let modeString = backgroundMode == .dark ? "Dark" : (backgroundMode == .black ? "Black" : "White")
            
            if url.pathExtension.lowercased() == "glb" {
                var fileSizeString = "Unknown size"
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? UInt64 {
                    let formatter = ByteCountFormatter()
                    formatter.allowedUnits = [.useAll]
                    formatter.countStyle = .file
                    fileSizeString = formatter.string(fromByteCount: Int64(size))
                }
                let progress = "\(currentIndex + 1) of \(imageURLs.count)"
                hudLabel.stringValue = "Background: \(modeString)   |   3D Model   |   \(fileSizeString)   |   \(progress)"
            } else {
                let dimensions = "\(Int(imageView.image?.size.width ?? 0)) × \(Int(imageView.image?.size.height ?? 0))"
                var fileSizeString = "Unknown size"
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? UInt64 {
                    let formatter = ByteCountFormatter()
                    formatter.allowedUnits = [.useAll]
                    formatter.countStyle = .file
                    fileSizeString = formatter.string(fromByteCount: Int64(size))
                }
                let progress = "\(currentIndex + 1) of \(imageURLs.count)"
                hudLabel.stringValue = "Background: \(modeString)   |   \(dimensions)   |   \(fileSizeString)   |   \(progress)"
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                if self.currentIndex >= 0 && self.currentIndex < self.imageURLs.count {
                    let activeURL = self.imageURLs[self.currentIndex]
                    if activeURL.pathExtension.lowercased() == "glb" {
                        self.updateHUDForGLB(with: activeURL)
                    } else if let img = self.imageView.image {
                        self.updateHUD(with: activeURL, image: img)
                    }
                }
            }
        }
    }
    
    private func updateHUDForGLB(with url: URL) {
        let filename = url.lastPathComponent
        
        var fileSizeString = "Unknown size"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useAll]
            formatter.countStyle = .file
            fileSizeString = formatter.string(fromByteCount: Int64(size))
        }
        
        let progress = "\(currentIndex + 1) of \(imageURLs.count)"
        hudLabel.stringValue = "\(filename)   |   3D Model   |   \(fileSizeString)   |   \(progress)"
        
        if let window = view.window {
            window.title = "\(filename) (\(progress))"
        }
    }
    
    // File Types menu actions
#if ENABLE_PNG
    @objc func togglePNGSupport(_ sender: AnyObject) {
        if activeExtensions.contains("png") {
            activeExtensions.remove("png")
        } else {
            activeExtensions.insert("png")
        }
        reloadDirectoryPreservingFocus()
    }
#endif
    
#if ENABLE_JPG
    @objc func toggleJPGSupport(_ sender: AnyObject) {
        if activeExtensions.contains("jpg") {
            activeExtensions.remove("jpg")
            activeExtensions.remove("jpeg")
        } else {
            activeExtensions.insert("jpg")
            activeExtensions.insert("jpeg")
        }
        reloadDirectoryPreservingFocus()
    }
#endif
    
#if ENABLE_SVG
    @objc func toggleSVGSupport(_ sender: AnyObject) {
        if activeExtensions.contains("svg") {
            activeExtensions.remove("svg")
        } else {
            activeExtensions.insert("svg")
        }
        reloadDirectoryPreservingFocus()
    }
#endif
    
#if ENABLE_EPS
    @objc func toggleEPSSupport(_ sender: AnyObject) {
        if activeExtensions.contains("eps") {
            activeExtensions.remove("eps")
        } else {
            activeExtensions.insert("eps")
        }
        reloadDirectoryPreservingFocus()
    }
#endif
    
#if ENABLE_TIFF
    @objc func toggleTIFSupport(_ sender: AnyObject) {
        if activeExtensions.contains("tif") {
            activeExtensions.remove("tif")
            activeExtensions.remove("tiff")
        } else {
            activeExtensions.insert("tif")
            activeExtensions.insert("tiff")
        }
        reloadDirectoryPreservingFocus()
    }
#endif
    
#if ENABLE_GLB
    @objc func toggleGLBSupport(_ sender: AnyObject) {
        if activeExtensions.contains("glb") {
            activeExtensions.remove("glb")
        } else {
            activeExtensions.insert("glb")
        }
        reloadDirectoryPreservingFocus()
    }
#endif

#if ENABLE_PDF
    @objc func togglePDFSupport(_ sender: AnyObject) {
        if activeExtensions.contains("pdf") {
            activeExtensions.remove("pdf")
        } else {
            activeExtensions.insert("pdf")
        }
        reloadDirectoryPreservingFocus()
    }
#endif
    
    func reloadDirectoryPreservingFocus() {
        guard currentIndex >= 0, currentIndex < imageURLs.count else { return }
        let currentURL = imageURLs[currentIndex]
        loadDirectory(focusingOn: currentURL, resetZoom: false)
    }
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Just keep items enabled; state sync is done in AppDelegate.menuWillOpen
        // which reads from whichever window is currently key.
        return true
    }
}

class ViewWindow: NSWindow {
    var previousFrame: NSRect?
    
    override func sendEvent(_ event: NSEvent) {
        // Intercept left double-click in the top titlebar area (top 30 pixels) to toggle fill screen
        if event.type == .leftMouseDown && event.clickCount == 2 {
            let point = event.locationInWindow
            if point.y > (self.frame.height - 30) && point.x > 80 {
                self.toggleFillScreen()
                return
            }
        }
        super.sendEvent(event)
    }
    
    func toggleFillScreen() {
        guard let screen = self.screen else { return }
        let visibleFrame = screen.visibleFrame
        
        // Check if the window is already maximized (allowing a 5px tolerance)
        let isMaximized = abs(frame.width - visibleFrame.width) < 5 && abs(frame.height - visibleFrame.height) < 5
        
        if isMaximized {
            // Restore previous window size
            if let prev = previousFrame {
                self.setFrame(prev, display: true, animate: true)
            } else {
                let defaultFrame = NSRect(x: (visibleFrame.width - 900) / 2 + visibleFrame.origin.x,
                                          y: (visibleFrame.height - 700) / 2 + visibleFrame.origin.y,
                                          width: 900,
                                          height: 700)
                self.setFrame(defaultFrame, display: true, animate: true)
            }
        } else {
            // Save current size and maximize to fill screen
            previousFrame = frame
            self.setFrame(visibleFrame, display: true, animate: true)
        }
    }
}

class ImageWindowController: NSWindowController, NSWindowDelegate {
    var controller: ImageViewController!
    
    convenience init(focusingOn fileURL: URL) {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let window = ViewWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                                styleMask: styleMask,
                                backing: .buffered,
                                defer: false)
        self.init(window: window)
        
        window.delegate = self
        window.title = "View"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1.0)
        window.minSize = NSSize(width: 400, height: 300)
        
        controller = ImageViewController()
        window.contentViewController = controller
        
        // Load target file
        controller.loadDirectory(focusingOn: fileURL, autoEnableFormat: true)
    }
    
    func windowWillClose(_ notification: Notification) {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.removeWindowController(self)
        }
    }
    
    func windowDidResize(_ notification: Notification) {
        controller.zoomToFit()
    }
    
    func windowDidEnterFullScreen(_ notification: Notification) {
        controller.zoomToFit()
    }
    
    func windowDidExitFullScreen(_ notification: Notification) {
        controller.zoomToFit()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    
    var windowControllers: [ImageWindowController] = []
    var hasOpenedFile = false
    var lastWindowLocation = NSPoint(x: 100, y: 800)
    
    // References to the toggle submenus so we can act as their NSMenuDelegate
    var fileTypesMenu: NSMenu?
    var glbMenu: NSMenu?
    
    // NSMenuDelegate – called once before the menu appears. Reads from the key
    // window's ImageViewController so each window's toggles reflect its own state.
    func menuWillOpen(_ menu: NSMenu) {
        guard let vc = NSApp.keyWindow?.contentViewController as? ImageViewController else { return }
        for item in menu.items {
            guard let container = item.view as? ClickableStackView,
                  let toggle = container.arrangedSubviews.compactMap({ $0 as? NSSwitch }).first else {
                continue
            }
            var isOn: Bool? = nil
            
#if ENABLE_PNG
            if isOn == nil, item.action == #selector(ImageViewController.togglePNGSupport(_:)) {
                isOn = vc.activeExtensions.contains("png")
            }
#endif
#if ENABLE_JPG
            if isOn == nil, item.action == #selector(ImageViewController.toggleJPGSupport(_:)) {
                isOn = vc.activeExtensions.contains("jpg")
            }
#endif
#if ENABLE_TIFF
            if isOn == nil, item.action == #selector(ImageViewController.toggleTIFSupport(_:)) {
                isOn = vc.activeExtensions.contains("tif")
            }
#endif
#if ENABLE_SVG
            if isOn == nil, item.action == #selector(ImageViewController.toggleSVGSupport(_:)) {
                isOn = vc.activeExtensions.contains("svg")
            }
#endif
#if ENABLE_EPS
            if isOn == nil, item.action == #selector(ImageViewController.toggleEPSSupport(_:)) {
                isOn = vc.activeExtensions.contains("eps")
            }
#endif
#if ENABLE_GLB
            if isOn == nil, item.action == #selector(ImageViewController.toggleGLBSupport(_:)) {
                isOn = vc.activeExtensions.contains("glb")
            }
#endif
#if ENABLE_PDF
            if isOn == nil, item.action == #selector(ImageViewController.togglePDFSupport(_:)) {
                isOn = vc.activeExtensions.contains("pdf")
            }
#endif
            
            guard let finalIsOn = isOn else { continue }
            toggle.state = finalIsOn ? .on : .off
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu() // Create the application menu
        
        // Enable application to be active frontmost
        NSApp.activate(ignoringOtherApps: true)
        
        // Process arguments if launched via command line with file paths
        let args = ProcessInfo.processInfo.arguments
        if !hasOpenedFile && args.count > 1 {
            let validExtensions = supportedExtensions()
            for i in 1..<args.count {
                let filePath = args[i]
                let fileURL = URL(fileURLWithPath: filePath).standardized
                if validExtensions.contains(fileURL.pathExtension.lowercased()) {
                    openWindow(focusingOn: fileURL)
                    hasOpenedFile = true
                }
            }
            if hasOpenedFile { return }
        }
        
        // Fallback: ask for file, checking on the next runloop tick if we opened one already
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.hasOpenedFile {
                self.promptForFile()
            }
        }
    }
    
    func openWindow(focusingOn fileURL: URL) {
        let wc = ImageWindowController(focusingOn: fileURL)
        windowControllers.append(wc)
        
        if let window = wc.window {
            if windowControllers.count == 1 {
                window.center()
                lastWindowLocation = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            } else {
                lastWindowLocation = window.cascadeTopLeft(from: lastWindowLocation)
            }
        }
        wc.showWindow(nil)
    }
    
    func removeWindowController(_ wc: ImageWindowController) {
        if let index = windowControllers.firstIndex(of: wc) {
            windowControllers.remove(at: index)
        }
    }
    
    // Support drag and drop files onto the App Icon in Dock or Finder
    func application(_ application: NSApplication, open urls: [URL]) {
        let validExtensions = supportedExtensions()
        for url in urls {
            let fileURL = url.standardized
            if validExtensions.contains(fileURL.pathExtension.lowercased()) {
                hasOpenedFile = true
                openWindow(focusingOn: fileURL)
            }
        }
    }
    
    // Customize Dock Menu to show a list of open windows
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let activeControllers = windowControllers.filter { $0.window != nil }
        
        if activeControllers.isEmpty {
            return nil
        }
        
        for wc in activeControllers {
            if let window = wc.window {
                let title = window.title.isEmpty ? "Untitled" : window.title
                let item = NSMenuItem(title: title, action: #selector(focusWindowFromDock(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = wc
                menu.addItem(item)
            }
        }
        return menu
    }
    
    @objc func focusWindowFromDock(_ sender: NSMenuItem) {
        if let wc = sender.representedObject as? ImageWindowController,
           let window = wc.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func promptForFile() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose Images"
        let extensions = supportedExtensions()
        if #available(macOS 11.0, *) {
            openPanel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        } else {
            openPanel.allowedFileTypes = extensions
        }
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        
        let response = openPanel.runModal()
        
        if response == .OK {
            for url in openPanel.urls {
                self.openWindow(focusingOn: url)
                self.hasOpenedFile = true
            }
        } else {
            if self.windowControllers.isEmpty == true {
                NSApplication.shared.terminate(nil)
            }
        }
    }
    
    func setupMenu() {
        let mainMenu = NSMenu()
        
        // 1. App Menu
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        appMenu.addItem(withTitle: "About View", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit View", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        
        // 2. Tools Menu
        let toolsMenu = NSMenu(title: "Tools")
        let toolsMenuItem = NSMenuItem()
        toolsMenuItem.submenu = toolsMenu
        mainMenu.addItem(toolsMenuItem)
        
        // Background Submenu
        let bgMenuItem = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
        let bgSubmenu = NSMenu(title: "Background")
        bgSubmenu.addItem(withTitle: "Dark", action: #selector(ImageViewController.setBackgroundDark), keyEquivalent: "")
        bgSubmenu.addItem(withTitle: "Black", action: #selector(ImageViewController.setBackgroundBlack), keyEquivalent: "")
        bgSubmenu.addItem(withTitle: "White", action: #selector(ImageViewController.setBackgroundWhite), keyEquivalent: "")
        bgMenuItem.submenu = bgSubmenu
        toolsMenu.addItem(bgMenuItem)
        
        // File Types Submenu
        let typesMenuItem = NSMenuItem(title: "File Types", action: nil, keyEquivalent: "")
        let typesSubmenu = NSMenu(title: "File Types")
        
#if ENABLE_PNG
        typesSubmenu.addItem(createSwitchMenuItem(title: "PNG (.png)", tag: 99, isEnabled: true, action: #selector(ImageViewController.togglePNGSupport(_:)), target: nil))
#endif
#if ENABLE_JPG
        typesSubmenu.addItem(createSwitchMenuItem(title: "JPEG (.jpg, .jpeg)", tag: 98, isEnabled: true, action: #selector(ImageViewController.toggleJPGSupport(_:)), target: nil))
#endif
        typesSubmenu.addItem(NSMenuItem.separator())
#if ENABLE_SVG
        typesSubmenu.addItem(createSwitchMenuItem(title: "SVG (.svg)", tag: 100, isEnabled: false, action: #selector(ImageViewController.toggleSVGSupport(_:)), target: nil))
#endif
#if ENABLE_EPS
        typesSubmenu.addItem(createSwitchMenuItem(title: "EPS (.eps)", tag: 101, isEnabled: false, action: #selector(ImageViewController.toggleEPSSupport(_:)), target: nil))
#endif
#if ENABLE_TIFF
        typesSubmenu.addItem(createSwitchMenuItem(title: "TIFF (.tif, .tiff)", tag: 102, isEnabled: false, action: #selector(ImageViewController.toggleTIFSupport(_:)), target: nil))
#endif
#if ENABLE_PDF
        typesSubmenu.addItem(createSwitchMenuItem(title: "PDF (.pdf)", tag: 104, isEnabled: false, action: #selector(ImageViewController.togglePDFSupport(_:)), target: nil))
#endif
        
        typesMenuItem.submenu = typesSubmenu
        toolsMenu.addItem(typesMenuItem)
        self.fileTypesMenu = typesSubmenu
        typesSubmenu.delegate = self
        
#if ENABLE_GLB
        // 3. 3D Viewer Menu
        let viewerMenu = NSMenu(title: "3D Viewer")
        let viewerMenuItem = NSMenuItem()
        viewerMenuItem.submenu = viewerMenu
        mainMenu.addItem(viewerMenuItem)
        
        viewerMenu.addItem(createSwitchMenuItem(title: "GLB (.glb)", tag: 103, isEnabled: false, action: #selector(ImageViewController.toggleGLBSupport(_:)), target: nil))
        self.glbMenu = viewerMenu
        viewerMenu.delegate = self
#endif
        
        NSApplication.shared.mainMenu = mainMenu
    }
}

class MenuItemTarget: NSObject {
    let action: Selector
    weak var menuItem: NSMenuItem?
    
    init(action: Selector, menuItem: NSMenuItem) {
        self.action = action
        self.menuItem = menuItem
        super.init()
    }
    
    @objc func toggleAction(_ sender: NSSwitch) {
        // Use to: nil so AppKit routes via the responder chain of the current key
        // window. This is reliable even during menu tracking when NSApp.keyWindow
        // may transiently return nil or the wrong window.
        NSApp.sendAction(action, to: nil, from: sender)
        // Removed menuItem?.menu?.cancelTracking() to allow menu to stay open
    }
}

class ClickableStackView: NSStackView {
    var onClick: (() -> Void)?
    var menuTarget: MenuItemTarget?
    
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

func createSwitchMenuItem(title: String, tag: Int, isEnabled: Bool, action: Selector, target: AnyObject?) -> NSMenuItem {
    let menuItem = NSMenuItem()
    menuItem.action = action
    menuItem.target = target
    
    let container = ClickableStackView(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
    container.orientation = .horizontal
    container.alignment = .centerY
    container.distribution = .fill
    container.spacing = 8
    container.edgeInsets = NSEdgeInsets(top: 2, left: 14, bottom: 2, right: 14)
    
    let label = NSTextField(labelWithString: title)
    label.font = NSFont.menuFont(ofSize: 14)
    label.textColor = .labelColor
    label.isEditable = false
    label.isSelectable = false
    label.isBezeled = false
    label.drawsBackground = false
    
    let toggle = NSSwitch()
    toggle.state = isEnabled ? .on : .off
    toggle.tag = tag
    toggle.controlSize = .small
    
    let menuTarget = MenuItemTarget(action: action, menuItem: menuItem)
    container.menuTarget = menuTarget
    
    toggle.target = menuTarget
    toggle.action = #selector(MenuItemTarget.toggleAction(_:))
    
    container.addArrangedSubview(label)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    container.addArrangedSubview(spacer)
    container.addArrangedSubview(toggle)
    
    container.onClick = { [weak toggle, weak menuTarget] in
        guard let toggle = toggle, let menuTarget = menuTarget else { return }
        toggle.state = toggle.state == .on ? .off : .on
        menuTarget.toggleAction(toggle)
    }
    
    menuItem.view = container
    return menuItem
}

// Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) {
    app.run()
}
