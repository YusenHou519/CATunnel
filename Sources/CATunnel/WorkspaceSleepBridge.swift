import AppKit

@MainActor
final class WorkspaceSleepBridge {
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var active = true
    private let onSleep: @MainActor () -> Void
    private let onWake: @MainActor () -> Void

    init(center: NotificationCenter, onSleep: @escaping @MainActor () -> Void,
         onWake: @escaping @MainActor () -> Void) {
        self.center = center
        self.onSleep = onSleep
        self.onWake = onWake
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                // Begin suspension during notification delivery; owned processes may exit later.
                MainActor.assumeIsolated { self?.handleSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            }
        ]
    }

    func stop() {
        active = false
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func handleSleep() {
        guard active else { return }
        onSleep()
    }

    private func handleWake() {
        guard active else { return }
        onWake()
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}
