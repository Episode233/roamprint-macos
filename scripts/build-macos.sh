#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    echo "请在 macOS 上运行此脚本，需要 Xcode Command Line Tools。" >&2
    exit 1
fi
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
output_dir=${ROAMPRINT_OUTPUT_DIR:-"$repo_dir/dist"}
app_path="$output_dir/ZGCAxZGCIprinter.app"
signing_identity=${ROAMPRINT_SIGN_IDENTITY:--}
installer_identity=${ROAMPRINT_INSTALLER_IDENTITY:-}
version=${ROAMPRINT_VERSION:-0.2.1}
mkdir -p "$output_dir"

cd "$repo_dir/native"
xcrun swift test --arch arm64
xcrun swift build --configuration release --arch arm64
binary_dir=$(xcrun swift build --configuration release --arch arm64 --show-bin-path)
for binary in RoamPrint roamprint-service; do
    /usr/bin/lipo "$binary_dir/$binary" -verify_arch arm64
done
if [[ -e "$app_path" ]]; then
    echo "输出已存在：$app_path。请移走该目录后重新构建。" >&2
    exit 1
fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources/bin"
/usr/bin/install -m 755 "$binary_dir/RoamPrint" "$app_path/Contents/MacOS/ZGCAxZGCIprinter"
/usr/bin/install -m 755 "$binary_dir/roamprint-service" "$app_path/Contents/Resources/bin/roamprint-service"
/usr/bin/install -m 644 "$repo_dir/native/Resources/RoamPrint.ppd" "$app_path/Contents/Resources/RoamPrint.ppd"
/usr/bin/install -m 755 "$repo_dir/scripts/install-local-printer.sh" "$app_path/Contents/Resources/install-local-printer.sh"
/usr/bin/install -m 755 "$repo_dir/scripts/add-to-print-menu.command" "$app_path/Contents/Resources/add-to-print-menu.command"
/usr/bin/install -m 755 "$repo_dir/scripts/remove-local-printer.sh" "$app_path/Contents/Resources/remove-local-printer.sh"
/usr/bin/install -m 644 "$repo_dir/native/Resources/ThirdPartyNotices.txt" "$app_path/Contents/Resources/ThirdPartyNotices.txt"

cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.local.roamprint</string>
<key>CFBundleName</key><string>ZGCAxZGCIprinter</string>
<key>CFBundleDisplayName</key><string>ZGCAxZGCIprinter</string>
<key>CFBundleExecutable</key><string>ZGCAxZGCIprinter</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>连接企业打印平台，提交文档后刷卡取件。</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_path/Contents/Info.plist"
/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
/usr/bin/codesign --force --options runtime --sign "$signing_identity" "$app_path/Contents/Resources/bin/roamprint-service"
/usr/bin/codesign --force --options runtime --sign "$signing_identity" "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"

pkg_path="$output_dir/ZGCAxZGCIprinter-$version-arm64.pkg"
if [[ -e "$pkg_path" ]]; then
    echo "输出已存在：$pkg_path。请移走该文件后重新构建。" >&2
    exit 1
fi
# Always install at the new application path, even if an older RoamPrint.app exists.
component_plist="$output_dir/component.plist"
cat > "$component_plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
<key>RootRelativeBundlePath</key><string>ZGCAxZGCIprinter.app</string>
<key>BundleIsRelocatable</key><false/>
</dict></array></plist>
PLIST
pkg_args=(--component "$app_path" --component-plist "$component_plist" --install-location /Applications
          --identifier org.local.roamprint --version "$version")
if [[ -n "$installer_identity" ]]; then pkg_args+=(--sign "$installer_identity"); fi
/usr/bin/pkgbuild "${pkg_args[@]}" "$pkg_path"
echo "ARM64 应用：$app_path"
echo "安装包：$pkg_path"
if [[ "$signing_identity" == - ]]; then
    echo "此构建使用本地 ad-hoc 签名；尚未经过 Developer ID 签名和 Apple 公证。"
fi
