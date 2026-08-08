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

echo "📄 正在生成安装说明文档..."
cat << 'EOF' > "$STAGING_DIR/必看_解决“应用已损坏”问题.txt"
==================================================
  FaradayCage (法拉第笼) 安装与破壁指南
==================================================

📦 第 1 步：安装应用
--------------------------------------------------
  请将本窗口里的【FaradayCage.app】图标
  拖拽进旁边的【Applications】蓝色文件夹图标里。

🔐 第 2 步：破除“应用已损坏”警告（极其重要！）
--------------------------------------------------
  因为本开源软件未经苹果官方付费签名，直接打开会提示“已损坏”。
  拖拽完成后，请务必按以下步骤操作：

  ① 按下键盘上的 【Command ⌘ + 空格键】（或点击屏幕右上角放大镜），
     呼出聚焦搜索，输入“终端”或“Terminal”并按下回车打开它。
     
  ② 复制下面这行命令（包含所有的英文字母和空格）：

     xattr -cr /Applications/FaradayCage.app

  ③ 粘贴到黑色的终端窗口中，然后按下回车键（Enter）。

🚀 第 3 步：开始使用
--------------------------------------------------
  大功告成！没有任何弹窗。
  现在您可以去启动台里愉快地打开法拉第笼了。

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