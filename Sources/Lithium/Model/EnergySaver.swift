import Foundation
import IOKit.ps
import Observation
import WebKit

/// Settings › Advanced › Energy saving.
enum EnergySaving: String, CaseIterable {
    case always, onBattery, off
}

/// Energy saving mode, like Chrome's Energy Saver and Orion's Low Power Mode. While it is on,
/// background tabs sleep after 5 minutes instead of 10, their silent videos pause, and WebKit
/// slows their timers further the longer they stay hidden (`Browser.saveEnergy`). The tab shown,
/// its split partner, the floating player and tabs playing sound or in a call are left alone.
///
/// "On battery", the default, also follows macOS's Low Power Mode, so it never fights the user's
/// own choice there. Only that setting watches the power source, through an IOKit notification
/// sent as the Mac is plugged in or unplugged: nothing polls, and "Always" and "Off" watch nothing.
@MainActor
@Observable
final class EnergySaver {
    var mode: EnergySaving {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Preference.energySaving)
            watchPower()
            update()
        }
    }
    /// Observed by the toolbar's indicator.
    private(set) var isOn = false {
        didSet { if isOn != oldValue { onChange?() } }
    }
    /// Told when `isOn` changes; the browser applies it to its tabs.
    @ObservationIgnored var onChange: (() -> Void)?
    /// On battery or in Low Power Mode; replaced in tests.
    @ObservationIgnored var isOnLimitedPower: () -> Bool = {
        let sources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(sources)?.takeUnretainedValue() as String?
        return type == kIOPSBatteryPowerValue || ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    @ObservationIgnored private var watcher: PowerWatcher?

    /// Whether the power source is watched, for tests.
    var isWatchingPower: Bool { watcher != nil }

    init() {
        mode = UserDefaults.standard.string(forKey: Preference.energySaving).flatMap(EnergySaving.init(rawValue:)) ?? .onBattery
        watchPower()
        update()
    }

    /// Reads the power source again, as its notifications do.
    func update() {
        isOn = switch mode {
        case .always: true
        case .onBattery: isOnLimitedPower()
        case .off: false
        }
    }

    private func watchPower() {
        if mode == .onBattery {
            if watcher == nil { watcher = PowerWatcher { [weak self] in self?.update() } }
        } else {
            watcher = nil
        }
    }
}

/// Calls back on the main thread when the Mac is plugged in or unplugged, and when Low Power Mode
/// is turned on or off. Both stop with the object.
@MainActor
private final class PowerWatcher {
    private let changed: () -> Void
    nonisolated(unsafe) private var source: CFRunLoopSource?
    nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    init(_ changed: @escaping () -> Void) {
        self.changed = changed
        // The source runs its callback on the run loop it is added to: the main one.
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let watcher = Unmanaged<PowerWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.changed() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// WebKit already slows the timers of a page out of the window (a background tab) and stops its
/// animation frames. Energy saving lets it raise that slowdown the longer the page stays hidden,
/// as Safari does; WebKit doesn't raise it for a page playing sound or loading. Private
/// preferences, skipped by a WebKit without them.
@MainActor
enum BackgroundThrottling {
    private static let keys = ["hiddenPageDOMTimerThrottlingEnabled", "hiddenPageDOMTimerThrottlingAutoIncreases"]

    /// WebKit's own values, put back when energy saving ends.
    private static let defaults: [String: Bool] = {
        let preferences = WKPreferences()
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            guard preferences.responds(to: Selector("_\(key)")) else { return nil }
            return (preferences.value(forKey: key) as? Bool).map { (key, $0) }
        })
    }()

    static func apply(_ isOn: Bool, to webView: WKWebView) {
        let preferences = webView.configuration.preferences
        for key in keys {
            let setter = Selector("_set\(key.prefix(1).uppercased())\(key.dropFirst()):")
            guard preferences.responds(to: setter), let standard = defaults[key] else { continue }
            let value = isOn || standard
            if preferences.value(forKey: key) as? Bool != value { preferences.setValue(value, forKey: key) }
        }
    }

    /// Whether the web view's timers slow down more the longer it is hidden; nil from a WebKit
    /// without the preference. For tests.
    static func increases(in webView: WKWebView) -> Bool? {
        let preferences = webView.configuration.preferences
        guard preferences.responds(to: Selector("_hiddenPageDOMTimerThrottlingAutoIncreases")) else { return nil }
        return preferences.value(forKey: "hiddenPageDOMTimerThrottlingAutoIncreases") as? Bool
    }
}
