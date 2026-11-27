import Foundation
import LocalAuthentication
import Security
import AppKit
import Carbon

public enum KeychainAuthError: LocalizedError {
    case biometryUnavailable(String)
    case biometryFailed(String)
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case itemNotFound
    case accessControlUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .biometryUnavailable(let reason):
            return "Touch ID 不可用：\(reason)"
        case .biometryFailed(let reason):
            return "生物识别认证未通过：\(reason)"
        case .keychainWriteFailed(let status):
            return "写入钥匙串失败（OSStatus \(status)）。"
        case .keychainReadFailed(let status):
            return "读取钥匙串失败（OSStatus \(status)）。"
        case .itemNotFound:
            return "钥匙串中尚未保存该容器的 Touch ID 密钥，请先使用主密码解锁并启用 Touch ID。"
        case .accessControlUnavailable(let detail):
            return "无法以生物识别/设备密码保护主密码，已拒绝写入无 ACL 的钥匙串项：\(detail)"
        }
    }
}

/// 负责 Touch ID 生物识别与 Secure Enclave 保护的钥匙串密钥封装。
public final class KeychainAuthService {
    private let serviceName = "com.appvault.macos.vault-passphrase"

    public init() {}

    /// 检测当前设备是否支持 Touch ID。
    public func isBiometryAvailable() -> (available: Bool, reason: String?) {
        let context = LAContext()
        var error: NSError?
        let ok = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return (ok, error?.localizedDescription)
    }

    /// 将加密卷主密码以 Access Control 保护写入钥匙串。
    /// 优先 `.biometryCurrentSet`；若 entitlement 不足则回退为仍带 ACL 的 `.devicePasscode`。
    /// **绝不**写入无 `kSecAttrAccessControl` 的明文条目（FIX-03）。
    public func savePassphrase(_ passphrase: String, forVaultId vaultId: String) throws {
        deletePassphrase(forVaultId: vaultId)
        guard let data = passphrase.data(using: .utf8) else { return }

        var cfError: Unmanaged<CFError>?
        guard let biometryAC = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &cfError
        ) else {
            let detail = cfError?.takeRetainedValue().localizedDescription ?? "无法创建 biometry ACL"
            throw KeychainAuthError.accessControlUnavailable(detail)
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: vaultId,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: biometryAC
        ]

        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement || status == errSecParam || status == errSecAuthFailed {
            var passcodeError: Unmanaged<CFError>?
            guard let passcodeAC = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .devicePasscode,
                &passcodeError
            ) else {
                let detail = passcodeError?.takeRetainedValue().localizedDescription
                    ?? "biometry ACL 写入失败（OSStatus \(status)）且无法创建 devicePasscode ACL"
                throw KeychainAuthError.accessControlUnavailable(detail)
            }
            query[kSecAttrAccessControl as String] = passcodeAC
            status = SecItemAdd(query as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            if status == errSecMissingEntitlement {
                throw KeychainAuthError.accessControlUnavailable(
                    "当前签名缺少钥匙串 Access Control 权限（OSStatus \(status)），请使用稳定代码签名后重试"
                )
            }
            throw KeychainAuthError.keychainWriteFailed(status)
        }
    }

    /// 通过 Touch ID 验证并读取钥匙串中的加密卷主密码。
    public func retrievePassphraseWithTouchID(
        forVaultId vaultId: String,
        localizedReason: String = "解锁 AppVault 加密容器"
    ) async throws -> String {
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
            throw KeychainAuthError.biometryUnavailable(authError?.localizedDescription ?? "未配置 Touch ID")
        }

        do {
            let verified = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: localizedReason
            )
            guard verified else {
                throw KeychainAuthError.biometryFailed("用户取消或验证失败")
            }
        } catch {
            throw KeychainAuthError.biometryFailed(error.localizedDescription)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: vaultId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            throw KeychainAuthError.itemNotFound
        }
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainAuthError.keychainReadFailed(status)
        }
        return password
    }

    public func hasStoredPassphrase(forVaultId vaultId: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: vaultId,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public func deletePassphrase(forVaultId vaultId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: vaultId
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 检测 Caps Lock 与当前输入法名称（用于主密码输入提示）。
    public static func currentInputHints() -> (capsLockOn: Bool, inputSourceName: String) {
        let capsOn = NSEvent.modifierFlags.contains(.capsLock)
        var layoutName = "ABC"
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            layoutName = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }
        return (capsOn, layoutName)
    }
}
