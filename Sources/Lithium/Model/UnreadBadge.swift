import Foundation

/// What a pinned tab's tile shows over its icon, like a Dock badge. Kept in memory only, per tab.
/// Precedence: the page's own `setAppBadge` count wins over a count in its title; a dot (from
/// `setAppBadge()` without a count, or a notification) shows only when neither gives a count.
struct UnreadBadge: Equatable {
    enum AppBadge: Equatable {
        /// `setAppBadge()` without a count.
        case flag
        case count(Int)
    }

    enum Shown: Equatable {
        case dot
        case count(Int)
    }

    private(set) var appBadge: AppBadge?
    private(set) var titleCount: Int?
    /// Set by a notification, cleared when the user opens the tab.
    private(set) var isNotified = false

    var shown: Shown? {
        if case .count(let count) = appBadge { return .count(count) }
        if let titleCount { return .count(titleCount) }
        return appBadge == .flag || isNotified ? .dot : nil
    }

    /// nil is the flag; 0 clears it, as `clearAppBadge()` does.
    mutating func setAppBadge(_ count: Int?) {
        appBadge = count.map { $0 > 0 ? .count($0) : nil } ?? .flag
    }

    mutating func clearAppBadge() {
        appBadge = nil
    }

    mutating func setTitle(_ title: String) {
        titleCount = Self.count(inTitle: title)
    }

    mutating func notify() {
        isNotified = true
    }

    mutating func open() {
        isNotified = false
    }

    /// Another site's page: what the last one said through the page no longer applies.
    mutating func leaveSite() {
        appBadge = nil
        isNotified = false
    }

    static func label(_ count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }

    static func accessibilityLabel(_ shown: Shown) -> String {
        switch shown {
        case .dot: "Unread"
        case .count(let count): "\(label(count)) unread"
        }
    }

    /// The unread count a page puts in its title: "(3) Inbox", "[3] Chat", "Inbox (3) - Gmail",
    /// "Inbox (1,234) - Gmail", "Messages (3)". A count inside the title ("Windows (95) review") or a year at its end
    /// ("Film (2024)") is not one. "99+" reads as more than 99.
    static func count(inTitle title: String) -> Int? {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let found: (digits: Substring, more: Substring)?
        if let match = text.prefixMatch(of: TitleCleaner.counter) {
            found = (match.1, match.2)
        } else if let match = text.firstMatch(of: /\s\((\d{1,3}(?:,\d{3})+|\d{1,6})(\+?)\)\s+[-–—|·•]\s/) {
            found = (match.1, match.2)
        } else if let match = text.firstMatch(of: /\s[\(\[](\d{1,6})(\+?)[\)\]]$/),
                  !(match.2.isEmpty && (1900...2099).contains(Int(match.1) ?? 0)) {
            found = (match.1, match.2)
        } else {
            found = nil
        }
        guard let found, let count = Int(found.digits.filter { $0 != "," }), count > 0 else { return nil }
        // The first two patterns take any number of digits: "(9223372036854775807+)" is Int.max,
        // which can't take one more.
        return found.more.isEmpty ? count : min(count, 999_999) + 1
    }
}
