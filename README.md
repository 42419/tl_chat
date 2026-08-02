# tl_chat

基于 Tailscale 内网穿透的聊天应用（Flutter 客户端 + Node.js Hub 服务端）。

## tailscale_dart 依赖（路径依赖）

本项目通过**路径依赖**引用定制版 `tailscale` 包：`../tailscale_dart`
（即 https://github.com/42419/tailscale_dart 的本地克隆，上游为 danReynolds/tailscale_dart）。
该 fork 在官方基础上修复了：build hook 丢失 GOCACHE 环境变量、worker 清理竞态。

### 本地开发前提

`tailscale_dart` 需要和 `tl_chat` 同级（即 `../tailscale_dart`）：

```bash
cd <projects 目录>
git clone https://github.com/42419/tailscale_dart.git
```

### 更新 tailscale_dart 依赖

1. **同步上游更新**（在 `tailscale_dart` fork 目录，或 GitHub 网页点 Sync fork）：
   ```bash
   cd <tailscale_dart fork 目录>
   git remote add upstream https://github.com/danReynolds/tailscale_dart.git  # 只需一次
   git fetch upstream && git merge upstream/main
   git push origin main
   ```
2. **tl_chat 使用新代码**：路径依赖直接读本地目录，纯代码改动**无需 pub get** 即生效；
   仅当 fork 的依赖元数据（pubspec/版本）变化时才需要 `flutter pub get`。

> CI（release workflow）会额外把 `42419/tailscale_dart` 检出到 `../tailscale_dart`
> （路径依赖位置），因此仓库本身无需包含该依赖，保持项目干净。

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
