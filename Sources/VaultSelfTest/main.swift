import Foundation
import VaultCore

struct CheckError: Error, CustomStringConvertible {
    let description: String
}

func assertTrue(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckError(description: "断言失败：\(message)") }
}

func makeTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppVaultSelfTest_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func runCase(_ name: String, _ block: () throws -> Void) -> Bool {
    do {
        try block()
        print("  [PASS] \(name)")
        return true
    } catch {
        print("  [FAIL] \(name) -> \(error)")
        return false
    }
}

print("=== AppVault VaultCore 自动化验证 ===")
var allPassed = true

allPassed = runCase("1. 宿主机配置 0600 权限与加密卷内清单读写") {
    let tempRoot = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let store = VaultStorageStore(baseDirectory: tempRoot.appendingPathComponent("support"))
    let cfg = HostVaultConfig(containerPath: "/tmp/test.sparsebundle", maxSizeMB: 4096)
    try store.saveHostConfig(cfg)

    let loaded = try store.loadHostConfig()
    try assertTrue(loaded == cfg, "宿主机配置回读不一致")

    let attrs = try FileManager.default.attributesOfItem(atPath: store.configFileURL.path)
    let perms = attrs[.posixPermissions] as? Int
    try assertTrue(perms == 0o600, "config.json 权限应为 0600，实测 \(String(describing: perms))")

    let fakeMount = tempRoot.appendingPathComponent("mount", isDirectory: true)
    try FileManager.default.createDirectory(at: fakeMount, withIntermediateDirectories: true)
    let record = VaultAppRecord(
        displayName: "DemoApp",
        bundleId: "com.example.demo",
        version: "1.2.3",
        originalAppPath: "/Applications/DemoApp.app",
        vaultAppRelativePath: "apps/DemoApp.app",
        appSizeBytes: 1024
    )
    try store.saveManifest(EncryptedVaultManifest(apps: [record]), in: fakeMount)
    let loadedManifest = try store.loadManifest(in: fakeMount)
    try assertTrue(loadedManifest.apps.count == 1 && loadedManifest.apps.first?.bundleId == "com.example.demo", "卷内清单回读异常")
} && allPassed

allPassed = runCase("2. 软链桥接建立、安全撤除与真实目录冲突保护") {
    let tempRoot = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let fakeHome = tempRoot.appendingPathComponent("home", isDirectory: true)
    let fakeMount = tempRoot.appendingPathComponent("mount", isDirectory: true)
    let bridge = SymlinkBridge(homeDirectory: fakeHome)

    let vaultData = fakeMount.appendingPathComponent("data/com.demo/AppSupport", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultData, withIntermediateDirectories: true)
    try Data("secret".utf8).write(to: vaultData.appendingPathComponent("db.sqlite"))

    let mapping = DataMapping(
        label: "App Support",
        hostRelativePath: "Library/Application Support/Demo",
        vaultRelativePath: "data/com.demo/AppSupport"
    )

    try bridge.activateMappings([mapping], mountPoint: fakeMount)
    let hostURL = mapping.resolvedHostURL(homeDirectory: fakeHome)
    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: hostURL.path)
    try assertTrue(dest == vaultData.path, "软链目标不匹配")

    bridge.deactivateMappings([mapping], mountPoint: fakeMount)
    try assertTrue(!FileManager.default.fileExists(atPath: hostURL.path), "撤除软链后宿主路径仍存在")

    try FileManager.default.createDirectory(at: hostURL, withIntermediateDirectories: true)
    var rejected = false
    do {
        try bridge.activateMappings([mapping], mountPoint: fakeMount)
    } catch {
        rejected = true
    }
    try assertTrue(rejected, "宿主存在真实目录时未拒绝覆盖")
} && allPassed

allPassed = runCase("3. 目标 .app 解析、非沙盒检测与 ~/Library 数据扫描") {
    let tempRoot = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let fakeHome = tempRoot.appendingPathComponent("home", isDirectory: true)
    let fakeApp = tempRoot.appendingPathComponent("SampleTool.app", isDirectory: true)
    let contentsDir = fakeApp.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)

    let plist: [String: Any] = [
        "CFBundleIdentifier": "com.example.sampletool",
        "CFBundleDisplayName": "SampleTool",
        "CFBundleShortVersionString": "2.0.1"
    ]
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: contentsDir.appendingPathComponent("Info.plist"))

    let appSupport = fakeHome.appendingPathComponent("Library/Application Support/SampleTool", isDirectory: true)
    try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: appSupport.appendingPathComponent("state.json"))

    let service = AppIngestService(homeDirectory: fakeHome)
    let inspection = try service.inspectApp(at: fakeApp)
    try assertTrue(inspection.bundleId == "com.example.sampletool", "Bundle ID 解析错误")
    try assertTrue(inspection.displayName == "SampleTool", "名称解析错误")
    try assertTrue(!inspection.isSystemProtected && !inspection.isSandboxed, "误判为系统或沙盒应用")
    try assertTrue(inspection.candidates.count == 1, "未扫描到 ~/Library/Application Support 数据目录")
} && allPassed

if CommandLine.arguments.contains("--skip-disk-e2e") {
    print("  [SKIP] 4. AES-256 APFS 稀疏加密卷端到端（当前沙盒无 DiskArbitration，请在终端不带参数运行验证）")
} else {
    allPassed = runCase("4. AES-256 APFS 稀疏加密卷端到端：创建、错密拒绝、隐藏挂载、读写、安全卸载") {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let engine = SparseBundleEngine()
        let imageURL = tempRoot.appendingPathComponent("e2e.sparsebundle", isDirectory: true)
        let mountPoint = tempRoot.appendingPathComponent(".av_e2e_mnt", isDirectory: true)
        let e2eSecret = "e2e-\(UUID().uuidString)"

        try engine.createVault(at: imageURL, volumeName: "AppVaultE2E", maxSizeMB: 120, passphrase: e2eSecret)
        try assertTrue(FileManager.default.fileExists(atPath: imageURL.path), "加密容器未生成")

        var wrongRejected = false
        do {
            try engine.mountVault(imageURL: imageURL, mountPoint: mountPoint, passphrase: "wrong-\(UUID().uuidString)")
        } catch {
            wrongRejected = true
        }
        try assertTrue(wrongRejected, "错误密码未被拒绝")

        try engine.mountVault(imageURL: imageURL, mountPoint: mountPoint, passphrase: e2eSecret)
        defer {
            if engine.isMounted(mountPoint: mountPoint) {
                try? engine.unmountVault(mountPoint: mountPoint, force: true)
            }
        }
        try assertTrue(
            engine.isMounted(mountPoint: mountPoint),
            "挂载表未检测到私有挂载点（expected=\(engine.canonicalPath(for: mountPoint)), actual=\(engine.kernelMountPoint(for: mountPoint) ?? "nil")）"
        )
        try assertTrue(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent(".metadata_never_index").path), "缺少 .metadata_never_index")

        let probeFile = mountPoint.appendingPathComponent("apps/probe.txt")
        try Data("encrypted-ok".utf8).write(to: probeFile)
        try assertTrue(try String(contentsOf: probeFile) == "encrypted-ok", "加密卷文件读写校验失败")

        try engine.unmountVault(mountPoint: mountPoint)
        try assertTrue(!engine.isMounted(mountPoint: mountPoint), "卸载后挂载点仍在挂载表")
        try assertTrue(!FileManager.default.fileExists(atPath: mountPoint.path), "卸载后未清理空挂载目录")
    } && allPassed
}

if allPassed {
    print("=== 验证完成：所有已执行项均通过 ===")
    exit(0)
} else {
    print("=== 存在失败项 ===")
    exit(1)
}
