import Foundation
import Testing
@testable import NotAKey

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

@MainActor
struct FestiveTests {
    private let defaults: UserDefaults

    init() {
        let suite = "com.nevelen.notakey.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    @Test(arguments: [(12, 1), (12, 25), (12, 31), (1, 1), (1, 6)])
    func inSeason(month: Int, day: Int) {
        #expect(Festive.isInSeason(date(2026, month, day)))
    }

    @Test(arguments: [(11, 30), (1, 7), (6, 15)])
    func outOfSeason(month: Int, day: Int) {
        #expect(!Festive.isInSeason(date(2026, month, day)))
    }

    @Test func untouchedFollowsSeason() {
        #expect(Festive(defaults: defaults, now: { date(2026, 12, 10) }).isEnabled)
        #expect(!Festive(defaults: defaults, now: { date(2026, 11, 17) }).isEnabled)
    }

    @Test func disablingPersists() {
        Festive(defaults: defaults, now: { date(2026, 12, 10) }).isEnabled = false
        #expect(!Festive(defaults: defaults, now: { date(2026, 12, 20) }).isEnabled)
    }

    @Test func turningOnEarlyWorksNowAndAfterRelaunch() {
        let festive = Festive(defaults: defaults, now: { date(2026, 11, 17) })
        festive.isEnabled = true
        #expect(festive.isActive)
        #expect(Festive(defaults: defaults, now: { date(2026, 11, 18) }).isActive)
    }

    @Test func earlyOnLastsThroughTwelfthNightThenFollowsSeason() {
        Festive(defaults: defaults, now: { date(2026, 11, 17) }).isEnabled = true
        #expect(Festive(defaults: defaults, now: { date(2027, 1, 6) }).isActive)
        #expect(!Festive(defaults: defaults, now: { date(2027, 1, 7) }).isActive)
        #expect(!Festive(defaults: defaults, now: { date(2027, 11, 17) }).isActive)
        #expect(Festive(defaults: defaults, now: { date(2027, 12, 1) }).isActive)
    }

    @Test func untickingBeforeSeasonStillTurnsOnInDecember() {
        let festive = Festive(defaults: defaults, now: { date(2026, 11, 17) })
        festive.isEnabled = true
        festive.isEnabled = false
        #expect(!Festive(defaults: defaults, now: { date(2026, 11, 30) }).isActive)
        #expect(Festive(defaults: defaults, now: { date(2026, 12, 1) }).isActive)
    }

    @Test func untickingInSeasonLastsUntilSeasonEndsOnly() {
        Festive(defaults: defaults, now: { date(2026, 12, 10) }).isEnabled = false
        #expect(!Festive(defaults: defaults, now: { date(2027, 1, 6) }).isActive)
        #expect(Festive(defaults: defaults, now: { date(2027, 12, 1) }).isActive)
    }

    @Test func choiceInEarlyJanuaryEndsOnTheSeventh() {
        Festive(defaults: defaults, now: { date(2027, 1, 3) }).isEnabled = false
        #expect(!Festive(defaults: defaults, now: { date(2027, 1, 6) }).isActive)
        #expect(Festive(defaults: defaults, now: { date(2027, 12, 1) }).isActive)
    }

    @Test func tickingInFebruaryLastsUntilDecemberThenFollowsSeason() {
        Festive(defaults: defaults, now: { date(2027, 2, 10) }).isEnabled = true
        #expect(Festive(defaults: defaults, now: { date(2027, 11, 30) }).isActive)
        #expect(!Festive(defaults: defaults, now: { date(2028, 1, 7) }).isActive)
    }

    @Test func earlyOnExpiresWhileAppStaysOpen() {
        nonisolated(unsafe) var today = date(2026, 11, 17)
        let festive = Festive(defaults: defaults, now: { today })
        festive.isEnabled = true
        today = date(2027, 1, 7)
        festive.refreshSeason()
        #expect(!festive.isActive)
    }

    @Test func activeNeedsSeasonAndSetting() {
        let festive = Festive(defaults: defaults, now: { date(2026, 12, 10) })
        #expect(festive.isActive)
        festive.isEnabled = false
        #expect(!festive.isActive)
        #expect(!Festive(defaults: defaults, now: { date(2026, 7, 1) }).isActive)
    }

    @Test func refreshSeasonPicksUpNewDate() {
        nonisolated(unsafe) var today = date(2026, 11, 30)
        let festive = Festive(defaults: defaults, now: { today })
        #expect(!festive.isInSeason)
        today = date(2026, 12, 1)
        festive.refreshSeason()
        #expect(festive.isInSeason)
    }
}

struct SnowfallTests {
    @Test func thirtyFlakesWithinSpec() {
        #expect(Snowfall.flakes.count == 30)
        for flake in Snowfall.flakes {
            #expect((2...4).contains(flake.size))
            #expect((8...14).contains(flake.period))
            #expect((0...1).contains(flake.x))
            #expect((0...1).contains(flake.phase))
            #expect(abs(flake.drift) <= 12)
        }
    }

    @Test func flakeStaysOnScreenAndWraps() {
        let size = CGSize(width: 400, height: 800)
        let flake = Snowfall.Flake(x: 0.5, size: 3, period: 10, phase: 0, drift: 10)
        for time in stride(from: 0.0, through: 30, by: 0.5) {
            let point = Snowfall.position(of: flake, at: time, in: size)
            #expect((-flake.size...size.height + flake.size).contains(point.y))
            #expect((0...size.width).contains(point.x))
        }
        #expect(Snowfall.position(of: flake, at: 0, in: size).y == Snowfall.position(of: flake, at: 10, in: size).y)
    }

    @Test func flakeFallsDownward() {
        let size = CGSize(width: 400, height: 800)
        let flake = Snowfall.Flake(x: 0.5, size: 3, period: 10, phase: 0, drift: 0)
        #expect(Snowfall.position(of: flake, at: 2, in: size).y > Snowfall.position(of: flake, at: 1, in: size).y)
    }
}
