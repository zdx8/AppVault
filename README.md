# AppVault

原生 macOS 应用保险箱（隐藏 + AES-256 加密存储 + 应用分身），基于纯 Swift & SwiftUI 构建，零第三方依赖、零内核扩展、零 FUSE。

## 核心特性

- **原生 AES-256 APFS 加密稀疏卷（`.sparsebundle`）**：按实际写入动态增长，支持解锁态实时查看卷内占用，删除分身或还原应用后锁定时自动执行 `hdiutil compact` 回收主机磁盘空间。
- **三重隐身机制**：
  - **Finder 不可见**：容器设置 `hidden` 标志，解锁时以 `-nobrowse -noautoopen` 挂载至私有 `0700` 隐藏目录，不出现在 `/Volumes`、侧边栏或桌面。
  - **Spotlight 不可见**：加密卷根目录写入 `.metadata_never_index` 并禁用索引，锁定后底层为密文分片。
  - **Launchpad 不可见**：移入隐藏模式下自动移除原位 `.app` 并调用 `lsregister -u` 注销系统缓存；一键还原时自动恢复注册。
- **两种运行模式**：
  - **移入隐藏（原位移除）**：支持第三方非沙盒 `.app`，自动扫描并迁入 `~/Library/Application Support`、`Preferences`、`Caches`，解锁期通过事务化软链桥接，锁定即撤链。
  - **加密分身（保留原应用）**：使用 `ditto` 完整保留原版 Apple 代码签名与 `Info.plist` 复制进加密卷，分配独立卷内 `HOME` 并以 `createsNewApplicationInstance` 启动双开，精确按 PID 追踪，支持含微信在内的各类应用。
- **Touch ID / 主密码 + 自动重锁**：
  - 主密码通过 `stdin` 管道直通 `hdiutil`，不落盘、不进日志、不进剪贴板；支持系统钥匙串 `.biometryCurrentSet` Touch ID 解锁。
  - 监听目标进程退出（1.5s + `lsof` 校验）、系统休眠/锁屏、空闲超时、全局急锁快捷键（`⌃⌥⌘L`）以及退出 AppVault 本身，自动关闭已打开的受管应用并锁定卸载容器。
- **运行时安全加固**：失败次数持久化退避限流、路径穿越校验、提权路径白名单、子进程环境净化，以及 Release 模式 `PT_DENY_ATTACH` 反调试、动态库注入检测、代码签名完整性自校验与本地符号剥离。
- **shadcn/ui 原生界面**：遵循 shadcn/ui Zinc 浅/深色令牌（默认浅色主题，支持一键切换与顶栏同色融合），菜单栏常驻 + 独立管理窗口（关闭窗口自动隐藏 Dock 图标）。

## 系统要求

- macOS 14.0（Sonoma）或更高版本
- Apple Silicon 或 Intel Mac

## 从源码构建

```bash
# 运行核心引擎自检（含真实 AES-256 APFS 加密卷端到端测试）
swift run VaultSelfTest

# 编译 Release 版本并打包 dist/AppVault.app
./Scripts/package_app.sh

# 打开应用
open dist/AppVault.app
```

> 首次打开若触发系统未公证提示，可在「系统设置 → 隐私与安全性」中允许打开，或执行：
> `xattr -dr com.apple.quarantine dist/AppVault.app`

## 许可证

本项目采用 [MIT License](LICENSE) 开源。
