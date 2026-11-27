import Foundation
import AppKit
import Carbon

/// 负责监控受管应用进程退出、系统休眠/锁屏、键鼠空闲超时以及全局紧急锁定快捷键（⌃⌥⌘L）。
public final class ProcessWatcher {
    public var onManagedAppTerminated: ((_ bundleId: String, _ pid: pid_t) -> Void)?
    public var onSystemSleepOrLock: ((_ reason: String) -> Void)?
    public var onIdleTimeout: (() -> Void)?
    public var onPanicHotkey: (() -> Void)?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var idleTimer: Timer?
    private var idleThresholdSeconds: TimeInterval = 0
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private static var activeWatcher: ProcessWatcher?

    public init() {}

    deinit {
        stopAll()
    }

    public func startMonitoring(
        idleTimeoutMinutes: Int,
        enableSleepAndLock: Bool,
        enablePanicHotkey: Bool
    ) {
        stopAll()

        let wsCenter = NSWorkspace.shared.notificationCenter
        let termObs = wsCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier else { return }
            self?.onManagedAppTerminated?(bundleId, app.processIdentifier)
        }
        workspaceObservers.append(termObs)

        if enableSleepAndLock {
            let sleepObs = wsCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.onSystemSleepOrLock?("系统休眠")
            }
            workspaceObservers.append(sleepObs)

            let lockObs = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.onSystemSleepOrLock?("屏幕已锁定")
            }
            distributedObservers.append(lockObs)
        }

        configureIdleTimer(minutes: idleTimeoutMinutes)
        if enablePanicHotkey {
            registerPanicHotkey()
        }
    }

    public func configureIdleTimer(minutes: Int, active: Bool = true) {
        idleTimer?.invalidate()
        idleTimer = nil
        idleThresholdSeconds = TimeInterval(max(0, minutes) * 60)
        guard active, idleThresholdSeconds > 0 else { return }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let idle = Self.systemIdleSeconds()
            if idle >= self.idleThresholdSeconds {
                self.onIdleTimeout?()
            }
        }
    }

    /// 锁定态暂停空闲计时器、解锁态恢复，避免后台每 15 秒空转唤醒。
    public func setIdleTimerActive(_ active: Bool) {
        let minutes = Int(idleThresholdSeconds / 60)
        configureIdleTimer(minutes: minutes, active: active)
    }

    public func stopAll() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers { wsCenter.removeObserver(obs) }
        workspaceObservers.removeAll()

        let distCenter = DistributedNotificationCenter.default()
        for obs in distributedObservers { distCenter.removeObserver(obs) }
        distributedObservers.removeAll()

        idleTimer?.invalidate()
        idleTimer = nil
        unregisterPanicHotkey()
    }

    public static func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        let minSeconds = types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
        return max(0, minSeconds)
    }

    /// 注册全局紧急锁定快捷键 ⌃⌥⌘L（Carbon RegisterEventHotKey，无需辅助功能权限）。
    private func registerPanicHotkey() {
        unregisterPanicHotkey()
        Self.activeWatcher = self

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async {
                ProcessWatcher.activeWatcher?.onPanicHotkey?()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            nil,
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x41564C4B), id: 1) // 'AVLK'
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let keyCodeL = UInt32(kVK_ANSI_L)
        RegisterEventHotKey(keyCodeL, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregisterPanicHotkey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
        if Self.activeWatcher === self {
            Self.activeWatcher = nil
        }
    }
}
