import SwiftUI
import VaultCore

/// 应用导入与分身确认弹窗（替代内嵌卡片，保持主界面清爽）。
struct IngestConfirmSheetView: View {
    @Bindable var vm: AppVaultViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let inspection = vm.currentInspection {
                // Header
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("\(inspection.displayName).app")
                                .font(.system(size: 15, weight: .semibold))
                            Text(inspection.bundleId)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ShadcnTokens.mutedForeground)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text("原路径：\(inspection.appURL.path) · 体积 \(ByteFormatter.string(from: inspection.appSizeBytes))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(ShadcnTokens.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if inspection.isSystemProtected {
                        ShadcnBadge(text: "SIP 系统保护拦截", tone: .red)
                    } else if inspection.isSandboxed {
                        ShadcnBadge(text: "沙盒应用 · 支持加密分身", tone: .amber)
                    } else {
                        ShadcnBadge(text: "非沙盒 · 支持移入与分身", tone: .emerald)
                    }
                }
                .padding(18)

                Divider()

                if !inspection.isEligibleForClone {
                    Text("受 SIP 保护的系统内置应用不可移入或创建分身。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("导入模式", selection: $vm.ingestMode) {
                            Text("移入隐藏（原位移除）").tag(VaultAppMode.move)
                            Text("创建分身（保留原应用）").tag(VaultAppMode.clone)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if vm.ingestMode == .clone {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("分身显示名称")
                                    .font(.system(size: 12, weight: .medium))
                                TextField("例如：微信 (分身)", text: $vm.cloneCustomName)
                                    .textFieldStyle(.roundedBorder)
                                Text(inspection.isSandboxed
                                     ? "检测到原应用带 App Sandbox 标记：创建分身时将剥离分身的沙盒签名并赋予独立 Bundle ID 与卷内隔离 HOME，原 \(inspection.displayName) 保留在原位不受影响，支持双开。"
                                     : "原应用保留在 \(inspection.appURL.path) 不受影响；分身将获得独立 Bundle ID 与加密卷内专属 HOME 目录，支持与原应用双开，退出即自动重锁。")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(ShadcnTokens.mutedForeground)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else if inspection.isSandboxed {
                            Text("该应用包含 com.apple.security.app-sandbox，不支持直接跨卷软链移入隐藏；请切换到右侧「创建分身（保留原应用）」。")
                                .font(.system(size: 12))
                                .foregroundStyle(ShadcnTokens.redFg)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            if vm.ingestCandidates.isEmpty {
                                Text("未在 ~/Library 下扫描到现存数据目录，将仅迁入 .app 本体。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ShadcnTokens.mutedForeground)
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("一并迁入的关联数据（解锁时自动软链桥接）")
                                        .font(.system(size: 12, weight: .medium))
                                    ScrollView {
                                        VStack(spacing: 0) {
                                            ForEach($vm.ingestCandidates) { $cand in
                                                HStack {
                                                    Toggle(isOn: $cand.selected) {
                                                        Text("~/\(cand.hostRelativePath)")
                                                            .font(.system(size: 11.5, design: .monospaced))
                                                    }
                                                    .toggleStyle(.checkbox)
                                                    Spacer()
                                                    Text(ByteFormatter.string(from: cand.sizeBytes))
                                                        .font(.system(size: 11, design: .monospaced))
                                                        .foregroundStyle(ShadcnTokens.mutedForeground)
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                if cand.id != vm.ingestCandidates.last?.id { Divider() }
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 160)
                                    .background(ShadcnTokens.card)
                                    .clipShape(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD))
                                    .overlay(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD).stroke(ShadcnTokens.border, lineWidth: 1))
                                }
                            }
                        }

                        if let err = vm.errorMessage {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundStyle(ShadcnTokens.redFg)
                        }
                    }
                    .padding(18)
                }

                Divider()

                // Footer
                HStack(spacing: 10) {
                    let selectedDataBytes = vm.ingestCandidates.filter(\.selected).reduce(Int64(0)) { $0 + $1.sizeBytes }
                    let estimatedTotal = inspection.appSizeBytes + (vm.ingestMode == .move ? selectedDataBytes : 0)
                    Text(vm.ingestMode == .clone
                         ? "预计占容器 \(ByteFormatter.string(from: estimatedTotal)) · 保留原版签名与原应用"
                         : "预计占容器 \(ByteFormatter.string(from: estimatedTotal)) · 移入后注销 Launchpad")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                        .lineLimit(1)
                    Spacer()
                    Button("取消") {
                        vm.cancelIngest()
                    }
                    .buttonStyle(ShadcnButtonStyle(variant: .outline, compact: true))
                    .disabled(vm.isWorking)

                    if inspection.isEligibleForClone {
                        Button {
                            Task { await vm.confirmIngestCurrentApp() }
                        } label: {
                            HStack(spacing: 6) {
                                if vm.isWorking {
                                    ProgressView().controlSize(.small)
                                }
                                Text(vm.isWorking
                                     ? (vm.ingestMode == .clone ? "正在创建分身..." : "正在移入...")
                                     : (vm.ingestMode == .clone ? "创建加密分身" : "确认移入保险箱"))
                            }
                        }
                        .buttonStyle(ShadcnButtonStyle(variant: .primary, compact: true))
                        .disabled(vm.isWorking || (vm.ingestMode == .move && inspection.isSandboxed))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(ShadcnTokens.muted)
            }
        }
        .frame(width: 560)
        .background(ShadcnTokens.background)
        .preferredColorScheme(vm.themeMode.colorScheme)
    }
}
