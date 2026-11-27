import SwiftUI

/// 事后在设置页开启 Touch ID 时补写主密码进钥匙串的确认弹窗。
struct EnableTouchIDSheetView: View {
    @Bindable var vm: AppVaultViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "touchid")
                Text("绑定 Touch ID 解锁")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("输入一次加密容器主密码，将其写入系统硬件钥匙串（.biometryCurrentSet）以启用 Touch ID 解锁。")
                .font(.system(size: 12))
                .foregroundStyle(ShadcnTokens.mutedForeground)

            SecureField("输入加密容器主密码", text: $vm.enableTouchIDPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }

            if let err = vm.sheetLocalError ?? vm.errorMessage {
                Text(err).font(.system(size: 12)).foregroundStyle(ShadcnTokens.redFg)
            }

            HStack {
                Spacer()
                Button("取消") {
                    vm.enableTouchIDPassword = ""
                    vm.sheetLocalError = nil
                    vm.showEnableTouchIDSheet = false
                }
                .buttonStyle(ShadcnButtonStyle(variant: .outline, compact: true))

                Button("保存并启用") { submit() }
                    .buttonStyle(ShadcnButtonStyle(variant: .primary, compact: true))
                    .disabled(vm.enableTouchIDPassword.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 390)
        .background(ShadcnTokens.background)
        .preferredColorScheme(vm.themeMode.colorScheme)
    }

    private func submit() {
        let pwd = vm.enableTouchIDPassword
        vm.enableTouchIDPassword = ""
        vm.confirmEnableTouchID(passphrase: pwd)
    }
}
