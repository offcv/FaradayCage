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
cat << 'EOF' > "$STAGING_DIR/必看_破除损坏提示.txt"
==================================================
  FaradayCage (法拉第笼) 安装与破壁指南
==================================================

1. 安装应用：
   请将左侧的 FaradayCage.app 拖拽到右侧的 Applications 文件夹中。

2. 破除“应用已损坏”警告（极其重要！）：
   因为本开源软件未经苹果官方付费签名，直接打开会提示“已损坏”。
   请务必按以下步骤操作：

   ① 在电脑的右上角放大镜（聚焦搜索）中搜索并打开“终端” (Terminal)。
   ② 复制下面这行命令（包含所有的英文字母和空格）：

   xattr -cr /Applications/FaradayCage.app

   ③ 粘贴到终端黑框框中，然后按下回车键（Enter）。

3. 开始使用：
   搞定！现在您可以去 应用程序(Applications) 或 启动台(Launchpad) 中愉快地打开法拉第笼了。

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