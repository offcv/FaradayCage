# FaradayCage (法拉第笼) 🛡️

**一键屏蔽外界干扰，专注当前任务。**

FaradayCage 是一款纯原生的轻量级 macOS 菜单栏工具。它没有繁琐的界面，没有任何后台常驻的高资源消耗，通过极简的两个快捷键，瞬间帮你清理屏幕上杂乱的窗口，或者将你需要参考的核心资料死死“钉”在屏幕最上层。

---

## ✨ 核心功能

### 1. 🧹 终极最小化 (一键清屏)
还在用繁琐的四指捏合或者逐个点击黄色的最小化按钮吗？
*   按 `⌘ + ⇧ + M` (Command + Shift + M)：**瞬间最小化屏幕上的所有窗口**，给你一个干净的桌面。
*   按 `⌘ + ⌥ + M` (Command + Option + M)：**最小化除了当前正在使用的窗口之外的所有窗口**。只留下你当前正在专注的任务。

### 2. 📌 无痕窗口置顶 (画中画)
macOS 默认不支持窗口置顶。FaradayCage 采用了创新的底层投屏方案（基于苹果原生的 `ScreenCaptureKit`）：
*   在菜单栏点击 **“置顶当前窗口”**：你会发现当前窗口被死死“钉”在了最前面。无论你怎么切换其他软件，它都不会被盖住。
*   完美支持**点击穿透、调整大小、拖拽跟随**，而且拥有极致的 Retina 清晰度（内置 100ms 防抖热更新，拖拽缩放不掉帧、不模糊）。

---

## 🚀 安装与运行

### 方式一：直接下载安装（推荐）
在 GitHub 的 **Releases** 页面下载最新版本的 `FaradayCage_Install.dmg`。

1. 双击打开下载的 `.dmg` 文件。
2. 将 DMG 窗口里的 `FaradayCage.app` 拖拽到旁边的 `Applications` 文件夹图标中完成安装。
3. **⚠️ 极其重要（破除“文件已损坏”限制）**：由于本开源软件未经苹果官方付费签名，请按下键盘上的 【Command ⌘ + 空格键】 呼出搜索，打开系统自带的 **终端 (Terminal)**。
   点击下方代码块右上角的图标**一键复制**，粘贴到终端并按下回车：

```bash
xattr -cr /Applications/FaradayCage.app
```

4. 现在，您可以愉快地从启动台或应用程序文件夹里打开 FaradayCage 了！首次打开会提示授予**辅助功能**权限，请按照提示在系统设置中勾选即可。

### 方式二：自己编译代码
如果你是开发者，完全可以通过源码自己编译，感受纯 Swift 脚本编译的魅力。

```bash
# 1. 克隆代码
git clone https://github.com/your-username/FaradayCage.git
cd FaradayCage

# 2. 一键编译并安装到 /Applications
bash engineering/scripts/build.sh
```
> **开发者提示**：为了保证每次重新编译后系统权限（辅助功能）不被重置，强烈建议在 Mac 的“钥匙串访问”中创建一张名为 `FaradayCage Developer` 的代码签名证书。如果不创建，脚本也会自动降级使用临时签名，但每次编译都需要重新授权。

---

## 🛠 架构与技术细节

本项目拒绝臃肿，没有 `.xcodeproj` 工程文件，全部由原生的 Swift 源码 + 极简的 Bash 脚本构建。

想了解本项目是如何调用底层 `AXUIElement` 接口、如何解决 `ScreenCaptureKit` 的分辨率拉伸和 Tab 切换假死问题？请务必阅读我们的 [开发者架构指南 (ARCHITECTURE.md)](ARCHITECTURE.md)。

---

## 📜 开源协议

本项目基于 [GNU General Public License v3.0 (GPLv3)](LICENSE) 开源。欢迎任何人分发、修改、提交 PR，但在分发衍生作品时必须同样开源。
