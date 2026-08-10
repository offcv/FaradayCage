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

echo "📄 正在生成纯文本备用指南..."
cat << 'EOF' > "$STAGING_DIR/📄如果修复工具也打不开请看我.txt"
==================================================
  FaradayCage (法拉第笼) 备用破壁指南
==================================================

如果您在极少数最新的 macOS 系统中，连带扳手图标的
【🔧双击修复打不开问题】工具也被系统拦截提示“已损坏”，
请不要担心，这只是苹果未经签名应用的过度保护机制。

请按照以下两种常规方法之一进行手动操作：

✅【备选方法一：右键打开】(推荐)
请不要双击。请在 /Applications (应用程序) 文件夹中找到 FaradayCage，
按住键盘上的 Control (⌃) 键点击它，或者直接「右键」点击它，
然后在弹出的菜单中选择「打开」。
此时弹出的警告框中会多出一个「打开」按钮，点击即可永久放行。

🔧【备选方法二：终端一键修复】
打开系统自带的「终端」应用，复制并执行以下命令（全选复制）：

xattr -cr /Applications/FaradayCage.app

按下回车执行后，即可去启动台正常双击打开应用。

==================================================
EOF

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