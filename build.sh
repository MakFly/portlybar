#!/bin/zsh
set -euo pipefail

project_root="${0:A:h}"
dist_dir="$project_root/dist"
app_bundle="$dist_dir/PortlyBar.app"
install_app=0
run_app=0

for argument in "$@"; do
  case "$argument" in
    --install) install_app=1 ;;
    --run) run_app=1 ;;
    *) print -u2 "Unknown option: $argument"; exit 64 ;;
  esac
done

cd "$project_root"
swift build -c release --product PortlyBarApp
swift build -c release --product portlybar
bin_dir="$(swift build -c release --show-bin-path)"
version="$(sed -n 's/public let portlyBarVersion = "\([^"]*\)"/\1/p' "$project_root/Sources/PortlyBarCore/Version.swift")"
[[ -n "$version" ]] || { print -u2 "Unable to read PortlyBar version."; exit 65; }

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources/bin" "$app_bundle/Contents/Frameworks"
cp "$bin_dir/PortlyBarApp" "$app_bundle/Contents/MacOS/PortlyBar"
cp "$bin_dir/portlybar" "$app_bundle/Contents/Resources/bin/portlybar"
chmod +x "$app_bundle/Contents/MacOS/PortlyBar" "$app_bundle/Contents/Resources/bin/portlybar"

if [[ -d "$bin_dir/Sparkle.framework" ]]; then
  cp -R "$bin_dir/Sparkle.framework" "$app_bundle/Contents/Frameworks/"
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$app_bundle/Contents/MacOS/PortlyBar" 2>/dev/null || true
fi
for resource_bundle in "$bin_dir"/*.bundle(N); do
  cp -R "$resource_bundle" "$app_bundle/Contents/Resources/"
done
cp -R "$project_root/Sources/PortlyBarApp/Resources/en.lproj" "$app_bundle/Contents/Resources/"
cp -R "$project_root/Sources/PortlyBarApp/Resources/fr.lproj" "$app_bundle/Contents/Resources/"
mkdir -p "$app_bundle/Contents/Resources/skills"
cp -R "$project_root/skills/portlybar" "$app_bundle/Contents/Resources/skills/portlybar"
cp -R "$project_root/skills/portlybar-http-server" "$app_bundle/Contents/Resources/skills/portlybar-http-server"

cat > "$app_bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PortlyBar</string>
  <key>CFBundleDisplayName</key><string>PortlyBar</string>
  <key>CFBundleIdentifier</key><string>dev.portlybar.app</string>
  <key>CFBundleExecutable</key><string>PortlyBar</string>
  <key>CFBundleIconFile</key><string>PortlyBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict></plist>
PLIST

swift "$project_root/Scripts/make-icon.swift" "$app_bundle/Contents/Resources/PortlyBar.icns"
codesign --force --deep --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"

if (( install_app )); then
  destination="/Applications/PortlyBar.app"
  if [[ -e "$destination" ]]; then
    print -u2 "Refusing to overwrite $destination. Remove it explicitly first."
    exit 73
  fi
  cp -R "$app_bundle" "$destination"
  print "Installed: $destination"
fi

if (( run_app )); then
  open "$app_bundle"
fi

print "Built: $app_bundle"
