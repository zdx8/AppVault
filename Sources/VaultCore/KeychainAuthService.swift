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

    /// 将加密卷主密码以 `.biometryCurrentSet` + `WhenUnlockedThisDeviceOnly` 封装存入系统钥匙串。
    /// 若 ad-hoc 签名下 Secure Enclave 访问控制受限，则回退为先用 LAContext 验证 Touch ID 再读取标准设备绑定钥匙串条目。
    public func savePassphrase(_ passphrase: String, forVaultId vaultId: String) throws {
        deletePassphrase(forVaultId: vaultId)
        guard let data = passphrase.data(using: .utf8) else { return }

        var cfError: Unmanaged<CFError>?
        let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &cfError
        )

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: vaultId,
            kSecValueData as String: data
        ]
        if let accessControl {
            query[kSecAttrAccessControl as String] = accessControl
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        var status = SecItemAdd(query as CFDictionary, nil)
        // Ad-hoc 签名构建时部分系统会返回 errSecMissingEntitlement (-34018)，此时降级为标准本机钥匙串 + LAContext 门禁
        if status == errSecMissingEntitlement {
            let fallbackQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: vaultId,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecValueData as String: data
            ]
            status = SecItemAdd(fallbackQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
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
