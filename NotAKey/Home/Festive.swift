import Foundation
import Observation

/// The Christmas look: on by itself from 1 December to Twelfth Night (6 January).
/// Settings can turn it off, or on early; an early "on" lasts until that season ends.
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
        expireEarlyChoice()
    }

    /// Checks the date again, for an app left open across the season's first or last day.
    func refreshSeason() {
        let inSeason = Self.isInSeason(now())
        if inSeason != isInSeason { isInSeason = inSeason }
        expireEarlyChoice()
    }

    /// An "on" made before or during a season ends with it, so the look can't stay on all year.
    private func expireEarlyChoice() {
        guard choice == true else { return }
        guard let chosenAt = defaults.object(forKey: Self.chosenAtKey) as? Date,
              now() > Self.seasonEnd(after: chosenAt) else { return }
        choice = nil
        defaults.removeObject(forKey: Self.settingKey)
        defaults.removeObject(forKey: Self.chosenAtKey)
    }

    /// 1 December to 6 January inclusive.
    nonisolated static func isInSeason(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return parts.month == 12 || (parts.month == 1 && (parts.day ?? 0) <= 6)
    }

    /// The first moment after the season `date` falls in, or the next one if it's out of season.
    nonisolated static func seasonEnd(after date: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.month == 1 && (parts.day ?? 0) <= 6 ? parts.year! : parts.year! + 1
        return calendar.date(from: DateComponents(year: year, month: 1, day: 7))!
    }
}
