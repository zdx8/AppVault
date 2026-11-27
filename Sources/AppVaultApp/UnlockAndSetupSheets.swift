import SwiftUI
import VaultCore

/// 首次启动向导：创建 AES-256 APFS 加密稀疏捆绑映像。
struct SetupVaultSheetView: View {
    @Bindable var vm: AppVaultViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("初始化 AppVault 加密容器")
                        .font(.system(size: 15, weight: .semibold))
                    Text("将在 ~/Library/Application Support 下创建 AES-256 APFS 隐藏稀疏卷")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("主密码（请妥善备份，丢失无法找回）")
                        .font(.system(size: 12, weight: .medium))
                    SecureField("至少 8 位高强度密码", text: $vm.setupPassword)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("确认主密码")
                        .font(.system(size: 12, weight: .medium))
                    SecureField("再次输入主密码", text: $vm.setupConfirmPassword)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("稀疏卷容量上限")
                            .font(.system(size: 12, weight: .medium))
                        Text("按实际写入占用磁盘，可随时 compact 回收")
                            .font(.system(size: 11))
                            .foregroundStyle(ShadcnTokens.mutedForeground)
                    }
                    Spacer()
                    Picker("", selection: $vm.setupMaxSizeGB) {
                        Text("10 GB").tag(10)
                        Text("20 GB").tag(20)
                        Text("50 GB").tag(50)
                        Text("100 GB").tag(100)
                    }
                    .frame(width: 110)
                }

                if vm.biometryAvailable {
                    Toggle(isOn: $vm.setupEnableTouchID) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启用 Touch ID 硬件钥匙串解锁")
                                .font(.system(size: 12, weight: .medium))
                            Text("指纹变动即自动失效，回退主密码输入")
                                .font(.system(size: 11))
                                .foregroundStyle(ShadcnTokens.mutedForeground)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }

            if let err = vm.sheetLocalError ?? vm.errorMessage {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(ShadcnTokens.redFg)
            }

            HStack {
                Spacer()
                Button {
                    guard vm.setupPassword.count >= 6 else {
                        vm.sheetLocalError = "主密码长度建议不少于 6 位。"
                        return
                    }
                    guard vm.setupPassword == vm.setupConfirmPassword else {
                        vm.sheetLocalError = "两次输入的主密码不一致。"
                        return
                    }
                    vm.sheetLocalError = nil
                    let pwd = vm.setupPassword
                    let sizeGB = vm.setupMaxSizeGB
                    let touch = vm.setupEnableTouchID
                    vm.setupPassword = ""
                    vm.setupConfirmPassword = ""
                    Task { await vm.createInitialVault(passphrase: pwd, maxSizeGB: sizeGB, enableTouchID: touch) }
                } label: {
                    if vm.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("创建加密容器并解锁")
                    }
                }
                .buttonStyle(ShadcnButtonStyle(variant: .primary))
                .disabled(vm.isWorking)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(ShadcnTokens.background)
    }
}

/// 解锁弹窗：Touch ID 优先 + 主密码回退（带 CapsLock 与输入法提示）。
struct UnlockSheetView: View {
    @Bindable var vm: AppVaultViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                    Text("解锁 AppVault 加密容器")
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                Button("取消") { vm.showUnlockSheet = false }
                    .buttonStyle(ShadcnButtonStyle(variant: .ghost, compact: true))
            }

            if vm.hostConfig?.touchIDEnabled == true && vm.hasTouchIDKeyStored {
                Picker("", selection: $vm.unlockAuthMode) {
                    Text("Touch ID").tag(0)
                    Text("主密码").tag(1)
                }
                .pickerStyle(.segmented)
            }

            if vm.unlockAuthMode == 0 && vm.hostConfig?.touchIDEnabled == true && vm.hasTouchIDKeyStored {
                VStack(spacing: 10) {
                    Image(systemName: "touchid")
                        .font(.system(size: 32))
                        .foregroundStyle(ShadcnTokens.foreground)
                        .padding(12)
                        .background(ShadcnTokens.secondary, in: Circle())
                    Text("轻触 Touch ID 验证身份")
                        .font(.system(size: 13, weight: .medium))
                    Text("验证通过后将从钥匙串取密并私有挂载（-nobrowse）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                    Button {
                        Task { await vm.unlockWithTouchID() }
                    } label: {
                        Text(vm.isWorking ? "正在解锁..." : "发起 Touch ID 认证")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ShadcnButtonStyle(variant: .primary))
                    .disabled(vm.isWorking)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("主密码")
                        .font(.system(size: 12, weight: .medium))
                    SecureField("输入加密容器主密码...", text: $vm.unlockPasswordInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitPassword() }

                    HStack {
                        Text("经 stdin 管道传入，不落盘")
                        Spacer()
                        if vm.unlockCapsLockOn {
                            Text("大写锁定已开")
                                .foregroundStyle(ShadcnTokens.amberFg)
                        }
                        Text("输入法：\(vm.unlockInputSourceName)")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(ShadcnTokens.mutedForeground)

                    Button {
                        submitPassword()
                    } label: {
                        Text(vm.isWorking ? "正在挂载..." : "解锁并隐藏挂载")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ShadcnButtonStyle(variant: .primary))
                    .disabled(vm.unlockPasswordInput.isEmpty || vm.isWorking)
                    .padding(.top, 6)
                }
            }

            if let err = vm.errorMessage {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(ShadcnTokens.redFg)
            }
        }
        .padding(20)
        .frame(width: 390)
        .background(ShadcnTokens.background)
        .onAppear {
            vm.refreshUnlockHints()
        }
    }

    private func submitPassword() {
        let pwd = vm.unlockPasswordInput
        vm.unlockPasswordInput = ""
        Task { await vm.unlockWithPassphrase(pwd, methodLabel: "主密码") }
    }
}

/// 数据软链映射详情弹窗。
struct MappingDetailSheetView: View {
    let app: VaultAppRecord
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(app.displayName) — 软链映射详情")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("关闭", action: onClose)
                    .buttonStyle(ShadcnButtonStyle(variant: .outline, compact: true))
            }

            Text("解锁启动时自动建立以下符号链接；应用退出并锁定容器时全部撤除，宿主机不残留数据目录。")
                .font(.system(size: 11.5))
                .foregroundStyle(ShadcnTokens.mutedForeground)

            if app.dataMappings.isEmpty {
                Text("该应用未关联 ~/Library 数据目录（仅隐藏加密 .app 本体）。")
                    .font(.system(size: 12))
                    .foregroundStyle(ShadcnTokens.mutedForeground)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(app.dataMappings) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(m.label).font(.system(size: 12.5, weight: .semibold))
                                Spacer()
                                Text(ByteFormatter.string(from: m.sizeBytes))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(ShadcnTokens.mutedForeground)
                            }
                            Text("宿主：~/\(m.hostRelativePath)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ShadcnTokens.mutedForeground)
                            Text("卷内：<private-mount>/\(m.vaultRelativePath)")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .padding(10)
                        if m.id != app.dataMappings.last?.id { Divider() }
                    }
                }
                .background(ShadcnTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD))
                .overlay(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD).stroke(ShadcnTokens.border, lineWidth: 1))
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(ShadcnTokens.background)
    }
}

/// 修改主密码弹窗（需在锁定状态执行）。
struct ChangePasswordSheetView: View {
    @Bindable var vm: AppVaultViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("修改加密容器主密码")
                .font(.system(size: 14, weight: .semibold))
            SecureField("当前主密码", text: $vm.changeOldPwd).textFieldStyle(.roundedBorder)
            SecureField("新主密码（至少 6 位）", text: $vm.changeNewPwd).textFieldStyle(.roundedBorder)
            SecureField("确认新主密码", text: $vm.changeConfirmPwd).textFieldStyle(.roundedBorder)
            if let err = vm.sheetLocalError ?? vm.errorMessage {
                Text(err).font(.system(size: 12)).foregroundStyle(ShadcnTokens.redFg)
            }
            HStack {
                Spacer()
                Button("取消") { vm.showChangePasswordSheet = false }
                    .buttonStyle(ShadcnButtonStyle(variant: .outline, compact: true))
                Button("确认更新") {
                    guard vm.changeNewPwd.count >= 6 else { vm.sheetLocalError = "新密码不少于 6 位"; return }
                    guard vm.changeNewPwd == vm.changeConfirmPwd else { vm.sheetLocalError = "两次新密码不一致"; return }
                    vm.sheetLocalError = nil
                    let oldP = vm.changeOldPwd
                    let newP = vm.changeNewPwd
                    vm.changeOldPwd = ""
                    vm.changeNewPwd = ""
                    vm.changeConfirmPwd = ""
                    Task { await vm.changeMasterPassword(oldPassword: oldP, newPassword: newP) }
                }
                .buttonStyle(ShadcnButtonStyle(variant: .primary, compact: true))
                .disabled(vm.isWorking)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(ShadcnTokens.background)
    }
}
