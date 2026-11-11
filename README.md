---
name: "iCut README"
description: "项目介绍：目标、使用方式与快速上手"
---

# iCut

## 项目简介

macOS 上的截图与贴图工具，参考 Snipaste：按一下快捷键即可框选屏幕内容，确认后图像进入剪贴板，同时变成一个置顶、可拖动的浮窗，用来对照参考、临时摆放或快速粘贴。

## 目标

- 打通「快捷键唤起 → 框选 → 复制到剪贴板 + 贴图浮窗」的最小闭环，响应速度与操作直觉对齐 Snipaste。
- macOS 优先；Windows 版为可选后续项，独立实现。
- 后续迭代补齐窗口智能识别、标注工具、保存文件、贴图增强、OCR、长截图等能力。

## 核心功能

v0.1 范围（开发中，尚未实现）：

- 菜单栏常驻，无 Dock 图标
- ⌘⇧2 全局快捷键唤起截图
- 多屏冻结截取 + 鼠标拖拽框选（选区压暗遮罩、实时尺寸标签）
- 确认后自动复制到系统剪贴板
- 贴图浮窗：置顶、跨 Space 可见、拖动移动、滚轮缩放、Esc 关闭、右键菜单

规划中（P1 / P2）：窗口智能识别、矩形/箭头/文字/马赛克标注、保存 PNG、贴图透明度与旋转、OCR、长截图、设置面板、历史记录。

## 快速上手

### 环境要求

- macOS 13.0 及以上（开发机为 macOS 13.7.8 / Intel）
- Xcode Command Line Tools（Swift 5.8+），**不需要完整 Xcode**

### 安装（下载安装包）

发布包由 GitHub Actions 构建并挂在 Releases 页面，文件名形如 `iCut-v0.1.0.zip`。解压后把 `iCut.app` 拖进 `/Applications`。

安装包为 ad-hoc 签名、未经 Apple 公证，首次打开会被 Gatekeeper 拦截：在 Finder 里右键 `iCut.app` 选「打开」，或执行：

```bash
xattr -dr com.apple.quarantine /Applications/iCut.app
```

### 开发构建（本地验证）

```bash
./scripts/build-app.sh             # 编译 + 组装 + ad-hoc 签名，输出 dist/iCut.app
./scripts/build-app.sh --universal # arm64 + x86_64 双架构（CI 使用，本地也可跑）
open dist/iCut.app                 # 启动
```

产物只出现在 `dist/`（编译中间文件在 `build/`），都不参与版本控制。**发布安装包不在本地构建**，统一由 GitHub Actions 产出；本地打包的唯一作用是拿到真实 bundle 身份，以便验证屏幕录制权限。

说明：本机只装了 Command Line Tools，没有 Xcode 的 `Platforms` 目录，`swift build` / `swift test` 会因缺少 `PlatformPath` 失败，因此构建直接用 `swiftc` + `lipo`，不依赖 SwiftPM。

### 授予屏幕录制权限

1. 首次运行按 ⌘⇧2，应用会提示需要「屏幕录制」权限。
2. 打开「系统设置 → 隐私与安全性 → 屏幕录制」，勾选 iCut。
3. 若系统提示需要重启应用，退出并重新启动 iCut。

重新打包后如果权限失效：在屏幕录制列表里选中 iCut 点 − 移除，再重新启动应用并授权。

> 请勿用 `swift run` 验证截图功能：那样进程的 TCC 身份是终端，授权会落在终端上。

## 使用方式

1. 按 ⌘⇧2（应用可在任意前台状态下响应）。
2. 按住鼠标拖拽框选区域；Esc 取消；Enter 或双击确认。
3. 确认后图像自动进入剪贴板，并生成一张贴图浮窗。
4. 拖动贴图可移动位置；滚轮以光标为中心缩放；Esc 关闭；右键菜单可复制或关闭。

## 目录结构

```
src/iCut/          Swift 源码（App / Core / Feature）
tests/iCutTests/   单元测试
scripts/           构建与打包脚本
resources/         打包资源（Info.plist）
.github/workflows/ GitHub Actions 构建配置
dist/              构建产物（不入库）
```

## 发布流程

1. 确认 `resources/Info.plist` 的版本号与本次 tag 一致。
2. 推送 tag（如 `v0.1.0`），GitHub Actions 自动构建 universal 包并创建 Release 附件。
3. 其余分支与 PR 的构建只产 artifact，不创建 Release。

## 开发说明

项目规范与过程文档（章程、需求、设计、WBS、检查清单）保存在本地工作区，不随仓库分发。
