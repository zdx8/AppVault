import Foundation
import Darwin
import MachO
import Security

public enum SecurityIntegrityStatus: Equatable {
    case passed
    case failed(reason: String)
}

/// 运行时防调试、防注入与二进制签名自校验模块（仅在 Release 构建中强制阻断，避免影响 Debug 开发）。
public final class SecurityHardening {
    public static let shared = SecurityHardening()
    private init() {}

    /// 1. 启用 XNU 内核级反附加（PT_DENY_ATTACH），阻止 lldb/gdb/Frida 附加调试进程。
    public func denyDebuggerAttach() {
        #if !DEBUG
        typealias PtraceFn = @convention(c) (CInt, pid_t, CInt, CInt) -> CInt
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "ptrace") else { return }
        let ptraceFn = unsafeBitCast(sym, to: PtraceFn.self)
        let PT_DENY_ATTACH: CInt = 31
        _ = ptraceFn(PT_DENY_ATTACH, 0, 0, 0)
        #endif
    }

    /// 2. 通过 sysctl 查询内核进程标志 P_TRACED，检测是否正被调试器跟踪。
    public func isBeingDebugged() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// 3. 检测环境变量注入（DYLD_INSERT_LIBRARIES 等）与已加载可疑动态库。
    public func detectDylibInjection() -> String? {
        let env = ProcessInfo.processInfo.environment
        let forbiddenEnvKeys = [
            "DYLD_INSERT_LIBRARIES",
            "DYLD_FORCE_FLAT_NAMESPACE",
            "DYLD_LIBRARY_PATH",
            "DYLD_FRAMEWORK_PATH"
        ]
        for key in forbiddenEnvKeys {
            if let val = env[key], !val.isEmpty {
                return "检测到异常注入环境变量：\(key)"
            }
        }

        let suspiciousMarkers = [
            "frida",
            "cycript",
            "substrate",
            "libhooker",
            "insert_dylib",
            "revealserver",
            "shadow"
        ]
        let count = _dyld_image_count()
        for i in 0..<count {
            guard let cName = _dyld_get_image_name(i) else { continue }
            let path = String(cString: cName).lowercased()
            // 仅检查非系统路径中的动态库名称
            if path.hasPrefix("/system/") || path.hasPrefix("/usr/lib/") { continue }
            for marker in suspiciousMarkers {
                if path.contains(marker) {
                    return "检测到可疑注入模块：\(URL(fileURLWithPath: path).lastPathComponent)"
                }
            }
        }
        return nil
    }

    /// 4. 校验自身 .app 包的代码签名完整性（防二进制 Patch / Info.plist 篡改）。
    public func verifySelfCodeSignature() -> SecurityIntegrityStatus {
        var selfCode: SecCode?
        let copyStatus = SecCodeCopySelf(SecCSFlags(), &selfCode)
        guard copyStatus == errSecSuccess, let code = selfCode else {
            return .failed(reason: "无法获取自身代码签名对象（OSStatus \(copyStatus)）")
        }

        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate)
        let validStatus = SecCodeCheckValidityWithErrors(code, flags, nil, &error)
        if validStatus == errSecSuccess {
            return .passed
        }
        let detail = error?.takeRetainedValue().localizedDescription ?? "OSStatus \(validStatus)"
        return .failed(reason: "应用签名完整性校验失败（可能被篡改）：\(detail)")
    }

    /// 综合自检（启动与解锁前调用）。
    public func runRuntimeIntegrityCheck() -> SecurityIntegrityStatus {
        #if DEBUG
        return .passed
        #else
        if isBeingDebugged() {
            return .failed(reason: "检测到调试器附加，已拒绝敏感操作")
        }
        if let injection = detectDylibInjection() {
            return .failed(reason: injection)
        }
        // 仅当以 .app Bundle 形态运行时校验签名
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            let sig = verifySelfCodeSignature()
            if case .failed = sig {
                return sig
            }
        }
        return .passed
        #endif
    }
}
