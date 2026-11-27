# AppVault 交接文档

> 按定版 HANDOVER 11 节填写。基线：FIX_LIST 全量代码修复后的本地工作树（待提交）。

---

## 1. 一句话结论

AppVault 是原生 macOS 应用保险箱（AES-256 APFS sparsebundle + 移入隐藏 / 加密分身），Swift 零第三方依赖；已开源至 GitHub `zdx8/AppVault` 与私有 Gitea `ZYG/AppVault`，官网 Pages 为 `zdx8.github.io/AppVault/`。当前工作树包含 FIX_LIST P0–P2 安全与稳定性修复，**尚未打新 tag / 建 Release DMG**（需另授对外授权）。

## 2. 交付物与位置

| 交付物 | 路径 | 说明 |
|---|---|---|
| 源码 | 本仓库根目录 | SPM：`VaultCore` / `AppVaultApp` / `VaultSelfTest` |
| 打包脚本 | `Scripts/package_app.sh`、`package_dmg.sh`、`create_local_signing_cert.sh` | 本地自签名 `AppVault Local Sign` |
| 产物（gitignore） | `dist/AppVault.app` | 不入库；用脚本现打 |
| 官网 | `docs/index.html` → GitHub Pages `/docs` | https://zdx8.github.io/AppVault/ |
| 修复清单 | `FIX_LIST.md` | 审查项与验收标准 |
| 远端 | GitHub `zdx8/AppVault`（公开）· Gitea `ssh://gitea/ZYG/AppVault.git`（私有） | `main` + tag `v0.1.0`（标签偏旧，见第 5 节） |

## 3. 怎么跑起来

```bash
cd <仓库根目录>

# 本机若遇 SPM 沙箱失败：
DISABLE_SANDBOX=1 ./Scripts/package_app.sh
# 或：
swift build -c release --disable-sandbox \
  --cache-path /tmp/spm-cache --config-path /tmp/spm-config --security-path /tmp/spm-security

swift run -c release --disable-sandbox \
  --cache-path /tmp/spm-cache --config-path /tmp/spm-config --security-path /tmp/spm-security \
  VaultSelfTest

open dist/AppVault.app
# 若 Gatekeeper 拦截：xattr -dr com.apple.quarantine dist/AppVault.app
```

系统要求：macOS 14+，Apple Silicon 或 Intel。首次创建保险箱会写 `~/Library/Application Support/com.appvault.macos/`。

## 4. 架构与关键设计

- **VaultCore**：`SparseBundleEngine`（hdiutil）、`AppIngestService`、`SymlinkBridge`、`KeychainAuthService`、`ProcessWatcher`、`SecurityHardening`、`PathSafety`、`VaultStorageStore`
- **AppVaultApp**：菜单栏 + 管理窗，`AppVaultViewModel` 编排解锁 / 导入 / 锁定
- **两种模式**：move（原位移除 + Library 软链）与 clone（ditto 保留签名 + 卷内 HOME 双开）
- **安全边界**：宿主明文配置不含应用名单；名单在卷内 `.vault/manifest.json`；主密码 stdin 管道进 hdiutil；提权仅 `/Applications` 与 `~/Applications`

## 5. 已完成 / 未完成 / 已知问题

**已完成**：核心引擎与 UI；Gitea/GitHub 首发；Pages；本地自签证书脚本；FIX_LIST P0–P2 代码修复与自检扩项。

**未完成**：Developer ID + 公证公开发布；`v0.1.0` 标签未指向含修复的 HEAD；GitHub Release DMG 未上传。

**已知问题**：ad-hoc/自签下签名自校验无法防「改完重签」（FIX-12 已文档化）；Touch ID 在缺 entitlement 时可能无法写入钥匙串（改为失败明示，不再无 ACL 降级）。

## 6. 外部依赖与凭据

- 系统工具：`hdiutil`、`codesign`、`lsregister`、`osascript`（提权）、`mdutil`、`lsof`
- 无第三方 Swift Package
- 凭据：主密码由用户设定；Touch ID 项在登录钥匙串 `com.appvault.macos.vault-passphrase`（须带 Access Control）
- **HANDOVER 不写任何明文密码或 Token**

## 7. 数据与配置在哪

| 数据 | 位置 | 权限 |
|---|---|---|
| 宿主配置 | `~/Library/Application Support/com.appvault.macos/config.json` | 0600 |
| 加密容器 | `…/containers/<vaultId>.sparsebundle` | hidden |
| 私有挂载点 | `~/Library/Caches/.av_<12hex>/` | 0700，锁定后删除 |
| 卷内清单 | `<mount>/.vault/manifest.json` | 仅解锁可读 |

## 8. 维护手册（出问题先看这里）

| 现象 | 处理 |
|---|---|
| 无法解锁 / 错密退避 | 看 `config.json` 的 `failedUnlockAttempts` / `unlockBlockedUntil`；冷却过后重试 |
| 卸载报资源忙 | 关掉受管应用；强制锁会 terminate；仍失败则看门狗应仍在跑（FIX-02） |
| Touch ID 无法启用 | 检查签名是否具备钥匙串 ACL；错误会明示，勿再期望无 ACL 回退 |
| 导入被拒 | 显示名/Bundle ID 含 `..` 或路径字符；或目标不在 `/Applications`、`~/Applications` |
| SPM `sandbox_apply` | `DISABLE_SANDBOX=1` |

## 9. 复现与验证清单

- [ ] `VaultSelfTest` 全过（含 3b 路径穿越 / 提权白名单）
- [ ] Release 编译通过
- [ ] `DISABLE_SANDBOX=1 ./Scripts/package_app.sh` 且 `codesign --verify --deep --strict`
- [ ] 手动：导入正常 app；恶意显示名 app 被拒；有进程时锁定保留看门狗；卸载失败后看门狗仍巡检

## 10. 下一步建议

1. 用户授权后：提交修复 → 推 Gitea/GitHub → 评估新 tag（如 `v0.1.1`）与 DMG Release  
2. 申请 Developer ID 并补公证流水线（原签名页路线 B）  
3. 真机回归：微信分身、移入隐藏、急锁 ⌃⌥⌘L、休眠自动锁  

## 11. 变更历史

| 日期 | 变更 |
|---|---|
| 2026-11-27 | 初版开源与 Pages；锁定早退/分身清单热修；本地自签证书；FIX_LIST P0–P2 全量落地与本交接文档 |
