#!/bin/bash
set -e

APP_NAME="FaradayCage"
DMG_NAME="FaradayCage_Install"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
BUILD_DIR="$PROJECT_DIR/engineering/build"
STAGING_DIR="$BUILD_DIR/dmg_staging"

echo "========================================="
echo "  法拉第笼 (FaradayCage) DMG 打包工具"
echo "========================================="
echo ""

# 检查应用是否已编译
if [ ! -d "$BUILD_DIR/$APP_NAME.app" ]; then
    echo "❌ 找不到编译好的 $APP_NAME.app"
    echo "请先运行 bash engineering/scripts/build.sh 进行编译！"
    exit 1
fi

echo "📁 准备 DMG 装配目录..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

echo "📦 复制应用文件和安装脚本..."
cp -R "$BUILD_DIR/$APP_NAME.app" "$STAGING_DIR/"
cp "$SCRIPT_DIR/install.command" "$STAGING_DIR/双击一键安装.command"

# 清理现有的 DMG（如果存在）
if [ -f "$BUILD_DIR/$DMG_NAME.dmg" ]; then
    rm -f "$BUILD_DIR/$DMG_NAME.dmg"
fi

echo "💿 正在压制 DMG 镜像..."
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$BUILD_DIR/$DMG_NAME.dmg"

echo ""
echo "🧹 清理临时文件..."
rm -rf "$STAGING_DIR"

echo "✅ 打包完成！"
echo "DMG 文件位置: $BUILD_DIR/$DMG_NAME.dmg"
echo ""
echo "现在您可以将 $DMG_NAME.dmg 发送给其他人使用了！"