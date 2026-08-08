#!/bin/bash
clear
echo "========================================="
echo "  法拉第笼 (FaradayCage) 一键安装程序"
echo "========================================="
echo ""

# 获取当前脚本所在目录（即 DMG 挂载的目录）
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_NAME="FaradayCage.app"
SOURCE_APP="$DIR/$APP_NAME"
TARGET_APP="/Applications/$APP_NAME"

if [ ! -d "$SOURCE_APP" ]; then
    echo "❌ 错误：找不到安装文件 ($SOURCE_APP)"
    echo "请确保您是从打开的 DMG 镜像中运行此脚本！"
    echo ""
    exit 1
fi

echo "📦 正在复制 $APP_NAME 到您的 应用程序 文件夹..."

# 如果应用程序文件夹已有旧版本，先删除
if [ -d "$TARGET_APP" ]; then
    echo "  - 发现旧版本，正在替换..."
    rm -rf "$TARGET_APP"
fi

cp -R "$SOURCE_APP" /Applications/

# 检查是否复制成功
if [ ! -d "$TARGET_APP" ]; then
    echo "❌ 错误：复制失败，可能是因为权限不足。"
    echo "请尝试手动将 $APP_NAME 拖入 /Applications 文件夹。"
    echo ""
    exit 1
fi

echo "✅ 复制成功！"
echo ""

echo "🔐 正在解除 macOS 隔离限制 (绕过“已损坏”提示)..."
xattr -cr "$TARGET_APP"
echo "✅ 隔离解除成功！"
echo ""

echo "🎉 安装完成！"
echo "您现在可以在 启动台(Launchpad) 或 应用程序文件夹中找到 FaradayCage。"
echo ""
echo "即将为您自动打开 法拉第笼..."
open "$TARGET_APP"

echo ""
echo "⚠️  首次打开会提示授予「辅助功能」和「屏幕录制」权限，请按照提示在系统设置中勾选。"
echo ""
echo "本窗口将在 5 秒后自动关闭..."
sleep 5
osascript -e 'tell application "Terminal" to close front window' 2>/dev/null
exit 0
