# AppVault 修复清单

> 来源：2026-11-27 代码审查（静态分析 + 编译验证 + 核心自检）
> 基线：HEAD `735ae5d`（`main`，已同步 `gitea/main`）；`v0.1.0` 标签指向 `4050e1a`
> 状态：**P0–P2 已实施**（2026-11-27）。REL-01/04/05 已在 `HANDOVER.md` / `README.md` 处理；本轮以 `v0.1.1` 对外同步。

---

## 一、优先级说明

| 级别 | 含义 | 数量 |
|---|---|---|
| P0 | 对外发布前必须修复；涉及用户数据删除权限、加密凭证保护或安全巡检失效 | 4 |
| P1 | 强烈建议修复；影响自动重锁可靠性与数据一致性 | 4 |
| P2 | 加固与清理；降低边缘场景风险 | 5 |
| REL | 发布与收尾阻塞项，非代码缺陷 | 5 |

---

## 二、P0 — 发布前必须修复

### FIX-01 [High] 导入应用时路径穿越，可越权复制并删除宿主文件

- **位置**
  - `Sources/VaultCore/AppIngestService.swift:95-102`（读取 `CFBundleDisplayName` / `bundleId`）
  - `Sources/VaultCore/AppIngestService.swift:139-165`（拼接 `hostRelativePath`）
  - `Sources/VaultCore/AppIngestService.swift:215-224`（`copyItem` + `removeItem`）
  - `Sources/VaultCore/AppIngestService.swift:282-302`（`restoreApp` 使用同一原始路径删除）
- **根因**：显示名与 Bundle ID 来自待导入 `.app` 的 Info.plist，未净化即拼入 `Library/Application Support/...`。`homeDirectory.appendingPathComponent("Library/Application Support/../../Documents")` 会解析为 `~/Documents`。`SymlinkBridge` 的 containment 校验只在解锁启动期生效，导入期没有任何校验。
- **影响**：恶意或被篡改的 `.app` 将显示名设为 `../../Documents` 时，用户点击导入即可把该目录复制进加密卷并从宿主删除；还原时二次越权删除。
- **修复动作**
  1. `inspectApp` 阶段净化 `displayName` / `bundleId`：拒绝 `/`、`..`、绝对路径、控制字符、空字符串。
  2. `discoverLibraryData` 中保存标准化后的 `hostRelativePath`。
  3. `ingestApp` 在每次 `copyItem` / `removeItem` 前校验：`srcURL` 经 `resolvingSymlinksInPath` 后严格位于 `~/Library` 内，`dstURL` 严格位于 `mountPoint` 内；任一失败中止整次导入。
  4. `restoreApp` 使用同样的校验。
  5. 补一条单元测试：模拟 `CFBundleDisplayName = "../../Documents"`，断言被拒绝。
- **验收**：恶意显示名被拒绝并给出明确错误；正常应用导入与还原流程无回归。
- **验证方式**：静态已确认代码路径存在；未构造恶意 app 实测，实施后必须补测。

### FIX-02 [High] 卸载失败后保险箱仍解锁，但完整性看门狗永久失效

- **位置**：`Sources/AppVaultApp/AppVaultViewModel.swift:343-345`（invalidate）、`352-401`（unmount do/catch）、`313`（唯一启动点）
- **根因**：`integrityTimer?.invalidate()` 位于 `unmountVault` 的 `do/catch` 之前；catch 分支只弹 alert 和写 `errorMessage`，不恢复定时器，也不改变 `isUnlocked` / `currentMountPoint`。
- **影响**：卷仍挂载且解锁，但防调试（`PT_DENY_ATTACH`）、动态库注入检测、签名自校验巡检全部停止，且此后不会自动重启。
- **修复动作**
  - 将 invalidate 推迟到卸载确认成功并与状态清理一起执行；**或**在两个 catch 分支中，若 `isUnlocked == true` 则调用 `startRuntimeIntegrityWatchdog()`。
  - 注意：受管进程仍在运行时的早退路径（335-341）**本身正确**，它有意保留看门狗；不要改动该分支。
- **验收**：模拟 `hdiutil detach` 失败（如占用进程），确认卷仍解锁期间看门狗每 10 秒仍在巡检；卸载成功后定时器停止。

### FIX-03 [High] Touch ID 回退让主密码脱离钥匙串 ACL

- **位置**：`Sources/VaultCore/KeychainAuthService.swift:71-81`
- **根因**：`SecItemAdd` 返回 `errSecMissingEntitlement` 时，代码静默改存无 `kSecAttrAccessControl` 的普通钥匙串项。读取侧（111-118）的 LAContext 验证只是应用自设门禁，钥匙串本身不对该条目强制生物识别。本项目 ad-hoc 签名下该回退很可能实际生效。
- **影响**：明文主密码可被同用户进程或被注入进程直接通过 `SecItemCopyMatching` 读出；README 中「Touch ID 钥匙串保护」声明在该路径不成立。
- **修复动作**
  1. 不要静默降级：回退条目也必须带 `SecAccessControl`（`.biometryCurrentSet`，至少 `.devicePasscode`）；否则拒绝保存并在 UI 明示。
  2. 评估启用 hardened runtime + 对应 entitlement，以消除回退前提。
  3. 在日志或设置页标注当前保护级别。
- **验收**：在 ad-hoc 签名构建下检查钥匙串条目的访问控制实际状态；无生物识别验证时无法读出主密码。

### FIX-04 [High→按 P0 处理] 提权「白名单」实为弱黑名单

- **位置**：`Sources/VaultCore/AppIngestService.swift:391-404`、`406-427`、`429-457`
- **根因**：`validateAppBundlePathForAdminOp` 仅检查 `.app` 后缀和 `/System`、`/usr`、`/bin`、`/sbin` 前缀黑名单，且 `standardizedFileURL` 不解析符号链接。任意用户目录下的 `*.app` 均可通过。manifest 位于解锁后的加密卷内，受管应用（普通用户权限）可改写 `originalAppPath`。
- **影响**：用户点击「还原」时，osascript 以 root 执行 `rm -rf` / `ditto`，目标可被导向任意 `.app` 结尾路径。
- **修复动作**
  1. 改为真白名单：仅允许 `/Applications/` 与 `~/Applications/` 下，且 `resolvingSymlinksInPath` 后仍位于白名单目录内。
  2. 校验目标是真实 `.app` bundle（存在 `Contents/Info.plist`）。
  3. 提权前对解析后的路径二次复核，不信任 manifest 中的原始字符串。
- **验收**：单元测试传入用户文档目录下的 `evil.app` 与指向 `/Applications` 的软链路径，均被拒绝。

---

## 三、P1 — 强烈建议修复

### FIX-05 [Medium] clone 退出检测缺 PID 回退，自动重锁可能永不触发

- **位置**：`Sources/AppVaultApp/AppVaultViewModel.swift:510-516`（尤其 514 行），自动重锁分支 522
- **根因**：`handleAppTerminated` 在 `runningPIDs` 找不到 pid 时，只回退匹配 `.mode == .move` 的记录；clone 与原应用 bundleId 相同但 mode 为 `.clone`，其 PID 一旦缺失（fork/exec、回调竞态）就不会被清理。
- **影响**：`runningPIDs` 永不为空，`autoLockOnQuit` 分支不触发，保险箱保持解锁。
- **修复动作**：回退匹配改为按 bundleId 且不限 mode；或为 clone 维护独立 PID 映射；用 `syncRunningState()` 定期校正。
- **验收**：启动 clone，模拟 PID 回调缺失，确认「全部退出自动锁定」仍触发。

### FIX-06 [Medium] 强制锁定与后台任务竞态

- **位置**：`Sources/AppVaultApp/AppVaultViewModel.swift:322-324` 缺 `!isWorking` 守卫；后台任务在 `568-574`、`609-611`、`631-633`、`731-733`
- **根因**：`lockVault` 的 guard 只检查 `isUnlocked`、`!isLockingInProgress`、`mountPoint`、`cfg`。休眠、锁屏、全局快捷键走 `force: true`，会在 `Task.detached` 的 clone / ingest / restore / compact 仍执行时卸载卷。
- **影响**：复制中断、manifest 与磁盘状态不一致、压缩失败。
- **修复动作**：把 `!isWorking` 纳入 guard，或用任务计数让强制锁定等待后台任务完成。
- **验收**：在 cloneApp 执行中触发紧急锁定，确认无半写入与 manifest 不一致。

### FIX-07 [Medium] 既有宿主软链被静默覆盖且回滚不恢复

- **位置**：`Sources/VaultCore/SymlinkBridge.swift:60-70`、`84-89`、`93-109`
- **根因**：宿主路径已是软链但目标不等于 `vaultURL.path` 时，第 66 行直接 `removeItem` 后替换；`createdLinks` 只记录本次新建链接，后续映射失败回滚不会恢复被删的旧软链；锁定时也不恢复。
- **影响**：用户自定义软链永久丢失。
- **修复动作**：遇到指向别处的软链按 `.hostPathOccupiedByRealFile` 类似方式拒绝并提示；或替换前备份，在回滚/锁定时恢复。

### FIX-08 [Medium] 路径穿越校验不解析符号链接，撤链前缀缺边界

- **位置**：`Sources/VaultCore/SymlinkBridge.swift:29-33`、`46-53`、`95`、`106`
- **根因**：`isStrictlyContained` 只做 `standardizedFileURL` + 字符串前缀，不调用 `resolvingSymlinksInPath`；`deactivateMappings` 的 `hasPrefix(mountPrefix)` 无路径边界。
- **影响**：宿主 `Library` 下若有指向外部的父级软链，桥接会落到 `~/Library` 之外；可能误删名字以挂载点名开头的相邻软链。
- **修复动作**：两侧都用 `resolvingSymlinksInPath` 后再做带边界的 containment 判断（根路径 + `/`）；复核最终 destination 真实路径。

---

## 四、P2 — 加固与清理

| 编号 | 严重度 | 位置 | 问题 | 修复动作 |
|---|---|---|---|---|
| FIX-09 | Low | `AppIngestService.swift:317-330,355` | clone 短 ID 仅 8 位十六进制（32 bit），碰撞时直接删除并覆盖另一分身目录，HOME 复用导致数据串号 | 改用完整 UUID 作目录名 |
| FIX-10 | Low | `SparseBundleEngine.swift:333-338` | 只清零局部 `bytes` 数组，`stdinString` 本体与传入 `write` 的 `Data` 拷贝未擦除 | 用 `withUnsafeMutableBytes` 覆写后再释放 |
| FIX-11 | Low | `SymlinkBridge.swift:135` | `cleanupOrphanedSymlinks` 按字符串包含 `/Library/Caches/.av_` 且断链即删，范围过宽 | 严格匹配 `~/Library/Caches/.av_[0-9a-f]{12}` 前缀 |
| FIX-12 | Low | `SecurityHardening.swift:77-93` | ad-hoc 自签下 `SecCodeCheckValidityWithErrors` 只校验与自身嵌入签名一致，攻击者改后重签即可通过 | 文档说明设计局限；正式签名 + 固定 team ID 校验 |
| FIX-13 | Low | `AppVaultViewModel.swift:827-830,523-527` | `Task` 强捕获 `self`，延后释放 2.4s / 1.5s | 改用 `[weak self]` |

---

## 五、REL — 发布与收尾阻塞项

| 编号 | 问题 | 处理 |
|---|---|---|
| REL-01 | 项目无 `HANDOVER.md`，`~/AiWork/.MEMORY/项目交接索引.md` 未登记 | 按 11 节模板补齐交接文档并登记索引 |
| REL-02 | `v0.1.0` 标签指向 `4050e1a`，HEAD `735ae5d` 的修复未进标签 | 修复完成后重新评估标签位置；对外 push/tag 需用户明确授权 |
| REL-03 | 历史提交曾带 Agent 协同署名 | 已用 filter-repo 从提交说明中移除；本轮 force-push 同步远端 |
| REL-04 | README 的 `./Scripts/package_app.sh` 在本环境因 SPM 沙箱失败（`sandbox_apply: Operation not permitted`） | README 补充 `DISABLE_SANDBOX=1`，或让脚本默认处理该参数 |
| REL-05 | `spctl` 拒绝本地自签应用（自签预期行为，非缺陷） | 公开发布需 Developer ID 签名 + 公证；本地使用说明保留 `xattr -dr com.apple.quarantine` |

---

## 六、已验证正确，请勿重复改动

1. **主密码传递**：create / attach / chpass 全程使用 `-stdinpass`、`-oldstdinpass -newstdinpass`，密码不进 argv、不落盘、不进日志；`changePassphrase` 的 `old\0new\0` 分隔符正确；`config.json` 权限 0600。
2. **锁定早退路径**（`AppVaultViewModel.swift:335-341`）：有意保留看门狗，跳过软链撤除/卸载/状态清理在「仍解锁且应用运行」时是正确设计。缺陷在其后的卸载失败分支（FIX-02）。
3. **clone 多记录**（`AppVaultViewModel.swift:577-580`）：只对 `.move` 去重，clone 各自 UUID 独立；UI 仅提供「删除分身」（`VaultManagerView.swift:405-417`），不存在误还原覆盖原应用。
4. **`runProcess`**（`SparseBundleEngine.swift:340-354`）：并发排空 stdout/stderr，无 64KB 管道死锁。
5. **挂载点防护**（`SparseBundleEngine.swift:96-108`）：拒绝符号链接、非本用户属主、非空目录，0700 创建，写入 `.metadata_never_index` 并执行 `mdutil -i off`。

---

## 七、验证命令（修复后执行）

```bash
cd <仓库根目录>

# 编译（本环境必须禁用 SPM 沙箱）
swift build -c release --disable-sandbox \
  --cache-path /tmp/spm-cache \
  --config-path /tmp/spm-config \
  --security-path /tmp/spm-security

# 核心自检（4 项，含真实 AES-256 APFS 稀疏卷端到端）
swift run --disable-sandbox \
  --cache-path /tmp/spm-cache \
  --config-path /tmp/spm-config \
  --security-path /tmp/spm-security VaultSelfTest

# 打包
DISABLE_SANDBOX=1 ./Scripts/package_app.sh
```

**注意**：`swift run` 默认 Debug 配置，`SecurityHardening` 中 Release 专属的 `PT_DENY_ATTACH`、注入检测与签名自校验不会被自检覆盖。Release 加固逻辑需单独设计验证方式。

---

## 八、基线核验记录（2026-11-27）

- Release 编译：通过（25.24 秒）
- VaultSelfTest：4/4 PASS，含加密卷创建、错密拒绝、隐藏挂载、读写、安全卸载
- 脚本语法：3 个 shell 脚本 `bash -n` 通过；`Info.plist` lint 通过
- 签名：`codesign --verify --deep --strict` 通过；`spctl` 拒绝（本地自签预期）
- 敏感信息扫描：源码、文档、提交历史未发现本机用户名、内网 IP、Gitea/NAS 端点或凭据
- 工作树：干净；HEAD `735ae5d`，HEAD@{0} 提交于 13:01，已同步 `gitea/main`
