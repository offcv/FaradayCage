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

echo "📦 复制应用文件并创建快捷方式..."
cp -R "$BUILD_DIR/$APP_NAME.app" "$STAGING_DIR/"
# 创建 Applications 文件夹软链接，实现拖拽安装体验
ln -s /Applications "$STAGING_DIR/Applications"

echo "📄 正在生成一键修复工具..."
# 使用 osacompile 将 AppleScript 编译成一个双击可运行的 App
# 这个 App 会通过管理员权限执行 xattr 清理命令
cat << 'EOF' > "$STAGING_DIR/fix_script.applescript"
try
    do shell script "xattr -cr /Applications/FaradayCage.app" with administrator privileges
    display dialog "修复完成！✅\n\n请前往「启动台」或「应用程序」文件夹中打开 FaradayCage。" buttons {"我知道了"} default button "我知道了" with title "修复成功" with icon note
on error errMsg
    display dialog "修复失败：\n" & errMsg buttons {"关闭"} default button "关闭" with title "发生错误" with icon stop
end try
EOF

osacompile -o "$STAGING_DIR/🔧双击修复打不开问题.app" "$STAGING_DIR/fix_script.applescript"
rm "$STAGING_DIR/fix_script.applescript"

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