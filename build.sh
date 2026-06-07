#!/bin/bash
set -e

echo "=== Compiling View Swift code ==="
mkdir -p .tmp
TMPDIR="$(pwd)/.tmp" swiftc -O main.swift -o View

echo "=== Creating macOS App Bundle ==="
# Clean old build if exists
rm -rf View.app

# Create folder structure
mkdir -p View.app/Contents/MacOS
mkdir -p View.app/Contents/Resources

# Move executable
mv View View.app/Contents/MacOS/View

# Copy bundled model-viewer JS for offline GLB support
if [ -f "model-viewer.min.js" ]; then
    cp model-viewer.min.js View.app/Contents/Resources/model-viewer.min.js
    echo "=== Bundled model-viewer.min.js for offline GLB support ==="
else
    echo "=== Warning: model-viewer.min.js not found. GLB viewing will require internet access ==="
fi

# Check and compile icon if app_icon.png is present in the workspace
if [ -f "app_icon.png" ]; then
    echo "=== Compiling application icon from app_icon.png ==="
    
    # Create temporary iconset
    mkdir -p View.iconset
    sips -s format png -z 16 16     app_icon.png --out View.iconset/icon_16x16.png
    sips -s format png -z 32 32     app_icon.png --out View.iconset/icon_16x16@2x.png
    sips -s format png -z 32 32     app_icon.png --out View.iconset/icon_32x32.png
    sips -s format png -z 64 64     app_icon.png --out View.iconset/icon_32x32@2x.png
    sips -s format png -z 128 128   app_icon.png --out View.iconset/icon_128x128.png
    sips -s format png -z 256 256   app_icon.png --out View.iconset/icon_128x128@2x.png
    sips -s format png -z 256 256   app_icon.png --out View.iconset/icon_256x256.png
    sips -s format png -z 512 512   app_icon.png --out View.iconset/icon_256x256@2x.png
    sips -s format png -z 512 512   app_icon.png --out View.iconset/icon_512x512.png
    sips -s format png -z 1024 1024 app_icon.png --out View.iconset/icon_512x512@2x.png
    
    # Compile iconset using macOS iconutil
    iconutil -c icns View.iconset -o View.app/Contents/Resources/AppIcon.icns
    
    # Cleanup temporary iconset directory (leaving app_icon.png intact)
    rm -rf View.iconset
    echo "=== Icon compiled and embedded successfully ==="
else
    echo "=== Notice: app_icon.png not found. Building without custom icon ==="
fi

# Write Info.plist
cat > View.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>View</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.view-app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>View</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Supported Images</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.png</string>
                <string>public.jpeg</string>
                <string>public.tiff</string>
                <string>public.svg-image</string>
                <string>com.adobe.encapsulated-postscript</string>
                <string>org.khronos.gltf.binary</string>
                <string>model.gltf.binary</string>
                <string>com.khronos.gltf</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

# Remove compilation artifacts
rm -rf .tmp

# Apply ad-hoc signature (Required for Apple Silicon architectures)
echo "=== Signing Application (Ad-Hoc) ==="
codesign --force --deep --sign - View.app

echo "=== View.app built successfully ==="
echo "You can launch the app by running:"
echo "  open View.app"
echo "Or with a specific image:"
echo "  open View.app --args /path/to/image.png"
