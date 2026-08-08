#!/bin/bash
set -e

APP_NAME="FaradayCage"
BUNDLE_ID="com.faradaycage"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
BUILD_DIR="$PROJECT_DIR/engineering/build"
APP_DIR="$PROJECT_DIR/engineering/app"

echo "========================================="
echo "  法拉第笼 (FaradayCage) - 屏蔽外界干扰"
echo "  构建脚本"
echo "========================================="
echo ""

# ── Step 1: 创建 .app 目录结构 ──
echo "📁 创建应用包结构..."
rm -rf "$BUILD_DIR/$APP_NAME.app"
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/Resources"

# ── Step 2: 编译（通用二进制 x86_64 + arm64）──
echo "⚙️  编译 main.swift (x86_64 + arm64) ..."
BIN_PATH="$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"
TMP_X86="/tmp/${APP_NAME}_x86"
TMP_ARM="/tmp/${APP_NAME}_arm"

swiftc -target x86_64-apple-macos12.3 \
    -framework Cocoa -framework Carbon \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    "$APP_DIR/main.swift" \
    -o "$TMP_X86"

swiftc -target arm64-apple-macos12.3 \
    -framework Cocoa -framework Carbon \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    "$APP_DIR/main.swift" \
    -o "$TMP_ARM"

lipo -create "$TMP_X86" "$TMP_ARM" -output "$BIN_PATH"
rm -f "$TMP_X86" "$TMP_ARM"

echo "✅ 编译成功"

# ── Step 3: 复制 Info.plist ──
cp "$APP_DIR/Info.plist" "$BUILD_DIR/$APP_NAME.app/Contents/"
echo "✅ Info.plist 已复制"

# ── Step 3.5: 复制图标 ──
cp "$APP_DIR/AppIcon.icns" "$BUILD_DIR/$APP_NAME.app/Contents/Resources/"
echo "✅ 应用图标已添加"

# ── Step 4: 代码签名（保持系统权限稳定的关键）──
# 【小白提示】为了让每次重新编译后，苹果系统依然认识这个软件，不重置辅助功能和录屏权限，
# 建议在 macOS 的“钥匙串访问”中创建一张名为 "FaradayCage Developer" 的代码签名证书。
# 如果系统里找不到这张证书，打包脚本会退级使用临时签名（软件照样能用，只是每次自己重新编译后，需要重新去系统设置里打个勾）。
echo "🔐 正在寻找本地证书进行签名..."
SIGN_IDENTITY="FaradayCage Developer"

# 检查证书是否存在
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    # 解锁专用签名钥匙串（如果存在）
    if [ -f /tmp/codesign.keychain-db ]; then
        security unlock-keychain -p "signing123" /tmp/codesign.keychain-db 2>/dev/null
    fi
    # 两步签名：先二进制，再 bundle
    codesign -f -s "$SIGN_IDENTITY" \
        "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>&1
    codesign -f -s "$SIGN_IDENTITY" \
        --identifier "$BUNDLE_ID" \
        "$BUILD_DIR/$APP_NAME.app" 2>&1
    echo "✅ 代码签名成功 (使用了证书: $SIGN_IDENTITY)"
    # 验证签名
    codesign -dvv "$BUILD_DIR/$APP_NAME.app" 2>&1 | grep -E "Identifier|Authority"
else
    echo "⚠️  未找到代码签名证书「$SIGN_IDENTITY」，将使用临时签名(-)"
    echo "    注意：这会导致您在下次重新编译后，系统辅助功能权限会被重置！"
    
    codesign -f -s "-" \
        "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>&1
    codesign -f -s "-" \
        --identifier "$BUNDLE_ID" \
        "$BUILD_DIR/$APP_NAME.app" 2>&1
    echo "✅ 临时签名成功"
fi

# ── Step 5: 复制到 /Applications ──
echo ""
echo "📦 正在安装到 /Applications ..."
if [ -d "/Applications/$APP_NAME.app" ]; then
    rm -rf "/Applications/$APP_NAME.app"
fi
cp -R "$BUILD_DIR/$APP_NAME.app" /Applications/
echo "✅ 已安装到 /Applications/$APP_NAME.app"

# ── Step 6: 完成 ──
echo ""
echo "========================================="
echo "  🎉 构建完成！"
echo "========================================="
echo ""
echo "  应用路径: /Applications/$APP_NAME.app"
echo ""
echo "  9.  正在启动 法拉第笼 ..."
open "/Applications/$APP_NAME.app"
echo ""
echo "  ⚠️  首次使用提示："
echo "  1. 点击菜单栏的 ➖ 图标"
echo "  2. 如果弹出权限提示，请前往："
echo "     系统设置 → 隐私与安全 → 辅助功能"
echo "     勾选「FaradayCage」"
echo "  3. 按 ⌘⇧M 最小化所有，按 ⌘⌥M 最小化其他"
echo ""