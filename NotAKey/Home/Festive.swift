import Foundation
import Observation

/// The Christmas look: on by itself from 1 December to Twelfth Night (6 January).
/// Settings can turn it off, or on early; either choice lasts until the season next starts or ends.
@MainActor @Observable
final class Festive {
    static let shared = Festive()
    static let settingKey = "notakey.festiveTheme"
    static let chosenAtKey = "notakey.festiveThemeChosenAt"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date

    /// The user's explicit choice; nil follows the season.
    private var choice: Bool?
    private(set) var isInSeason: Bool

    /// The Settings checkbox: the user's choice, or the season if they haven't made one.
    var isEnabled: Bool {
        get { choice ?? isInSeason }
        set {
            choice = newValue
            defaults.set(newValue, forKey: Self.settingKey)
            defaults.set(now(), forKey: Self.chosenAtKey)
        }
    }

    var isActive: Bool { isEnabled }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        choice = defaults.object(forKey: Self.settingKey) as? Bool
        isInSeason = Self.isInSeason(now())
        expireChoice()
    }

    /// Checks the date again, for an app left open across the season's first or last day.
    func refreshSeason() {
        let inSeason = Self.isInSeason(now())
        if inSeason != isInSeason { isInSeason = inSeason }
        expireChoice()
    }

    /// A choice lasts until the season next starts or ends, then the look follows the date again,
    /// so neither an early "on" nor an "off" sticks for good.
    private func expireChoice() {
        guard choice != nil else { return }
        guard let chosenAt = defaults.object(forKey: Self.chosenAtKey) as? Date,
              now() >= Self.nextBoundary(after: chosenAt) else { return }
        choice = nil
        defaults.removeObject(forKey: Self.settingKey)
        defaults.removeObject(forKey: Self.chosenAtKey)
    }

    /// 1 December to 6 January inclusive.
    nonisolated static func isInSeason(_ date: Date) -> Bool {
        let parts = gregorian.dateComponents([.month, .day], from: date)
        return parts.month == 12 || (parts.month == 1 && (parts.day ?? 0) <= 6)
    }

    /// The next 1 December or 7 January after `date`, whichever comes first.
    nonisolated static func nextBoundary(after date: Date) -> Date {
        let calendar = gregorian
        let year = calendar.component(.year, from: date)
        return [DateComponents(year: year, month: 1, day: 7),
                DateComponents(year: year, month: 12, day: 1),
                DateComponents(year: year + 1, month: 1, day: 7)]
            .compactMap(calendar.date(from:))
            .first { $0 > date }!
    }

    /// The season is a Gregorian one, whatever calendar the phone is set to.
    nonisolated private static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}
