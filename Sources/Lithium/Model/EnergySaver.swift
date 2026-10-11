import Foundation
import IOKit.ps
import Observation
import WebKit

enum EnergySaving: String, CaseIterable {
    case always, onBattery, off
}

/// Energy saving mode: background tabs sleep sooner, their silent videos pause, and WebKit slows
/// their timers further the longer they stay hidden (`Browser.saveEnergy`).
/// "On battery" also follows Low Power Mode, and is the only setting that watches the power
/// source, through an IOKit notification: nothing polls.
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
    private(set) var isOn = false {
        didSet { if isOn != oldValue { onChange?() } }
    }
    @ObservationIgnored var onChange: (() -> Void)?
    /// On battery or in Low Power Mode; replaced in tests.
    @ObservationIgnored var isOnLimitedPower: () -> Bool = {
        let sources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(sources)?.takeUnretainedValue() as String?
        return type == kIOPSBatteryPowerValue || ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    @ObservationIgnored private var watcher: PowerWatcher?

    /// For tests.
    var isWatchingPower: Bool { watcher != nil }

    init() {
        mode = UserDefaults.standard.string(forKey: Preference.energySaving).flatMap(EnergySaving.init(rawValue:)) ?? .onBattery
        watchPower()
        update()
    }

    /// The ⋯ menu's and the address bar's quick switch: Settings' Always or Off, since a switch
    /// flipped by hand shouldn't then wait on the power source.
    func turn(on: Bool) { mode = on ? .always : .off }

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

/// Calls back on the main thread when the Mac is plugged in or unplugged, or Low Power Mode changes.
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

/// Energy saving lets WebKit raise its hidden-page timer slowdown the longer a page stays hidden,
/// as Safari does. Private preferences, skipped by a WebKit without them.
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

    /// Nil from a WebKit without the preference. For tests.
    static func increases(in webView: WKWebView) -> Bool? {
        let preferences = webView.configuration.preferences
        guard preferences.responds(to: Selector("_hiddenPageDOMTimerThrottlingAutoIncreases")) else { return nil }
        return preferences.value(forKey: "hiddenPageDOMTimerThrottlingAutoIncreases") as? Bool
    }
}
