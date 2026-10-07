import Foundation
import Testing

@testable import MaxActCore

@Suite struct StravaRateLimitTests {
    /// 2026-10-07T10:07:00Z — seven minutes into a quarter hour, so the next boundary is 10:15.
    private let now = Date(timeIntervalSince1970: 1_791_367_620)

    private func headers(overall: String, overallLimit: String = "200,2000",
                         read: String, readLimit: String = "100,1000") -> [String: String] {
        ["X-RateLimit-Usage": overall, "X-RateLimit-Limit": overallLimit,
         "X-ReadRateLimit-Usage": read, "X-ReadRateLimit-Limit": readLimit]
    }

    @Test("with room in both buckets, a request may go now")
    func freshBudget() {
        var limit = StravaRateLimit()
        #expect(limit.earliestStart(for: .write, at: now) == now)
        #expect(limit.earliestStart(for: .read, at: now) == now)
    }

    @Test("headers replace the local count")
    func headersAreAuthoritative() {
        var limit = StravaRateLimit()
        limit.record(headers: headers(overall: "36,1200", read: "20,600"), at: now)
        #expect(limit.overall.shortTermUsed == 36)
        #expect(limit.overall.dailyUsed == 1200)
        #expect(limit.read.shortTermUsed == 20)
    }

    @Test("header names match case-insensitively, since HTTP/2 lower-cases them")
    func lowercaseHeaders() {
        var limit = StravaRateLimit()
        limit.record(headers: ["x-ratelimit-usage": "5,50", "x-ratelimit-limit": "200,2000"], at: now)
        #expect(limit.overall.shortTermUsed == 5)
    }

    @Test("an exhausted read bucket holds polls but not uploads")
    func pollsSpendTheReadBucket() {
        // The easy mistake: status polls are GETs. With the read bucket spent, an upload can still
        // go — but polling for its result has to wait for the quarter hour.
        var limit = StravaRateLimit()
        limit.record(headers: headers(overall: "120,500", read: "100,400"), at: now)
        #expect(limit.earliestStart(for: .write, at: now) == now)
        #expect(limit.earliestStart(for: .read, at: now) == StravaRateLimit.nextQuarterHour(after: now))
    }

    @Test("an exhausted daily limit waits for midnight UTC, not the quarter hour")
    func dailyExhaustion() {
        var limit = StravaRateLimit()
        limit.record(headers: headers(overall: "10,1999", read: "5,500"), at: now)
        #expect(limit.earliestStart(for: .write, at: now) == StravaRateLimit.nextMidnightUTC(after: now))
    }

    @Test("a margin is held back, because responses arrive after requests leave")
    func marginHeldBack() {
        var limit = StravaRateLimit()
        limit.record(headers: headers(overall: "197,500", read: "0,0"), at: now)
        #expect(limit.earliestStart(for: .write, at: now) == now)
        limit.spend(.write, at: now)
        #expect(limit.earliestStart(for: .write, at: now) > now, "198 of 200 leaves only the margin")
    }

    @Test("local spending stops a burst before the next response would")
    func optimisticSpending() {
        var limit = StravaRateLimit()
        limit.record(headers: headers(overall: "190,500", read: "0,0"), at: now)
        var sent = 0
        while limit.earliestStart(for: .write, at: now) == now && sent < 50 {
            limit.spend(.write, at: now)
            sent += 1
        }
        #expect(sent == 8, "190 + 8 = 198, the limit less the margin")
    }

    @Test("a quarter-hour boundary resets the short-term count but not the daily one")
    func quarterHourRollover() {
        var limit = StravaRateLimit()
        limit.record(headers: headers(overall: "199,800", read: "99,400"), at: now)
        let later = StravaRateLimit.nextQuarterHour(after: now).addingTimeInterval(1)
        #expect(limit.earliestStart(for: .read, at: later) == later)
        #expect(limit.overall.shortTermUsed == 0)
        #expect(limit.overall.dailyUsed == 800)
    }

    @Test("midnight UTC resets the daily count")
    func midnightRollover() {
        var limit = StravaRateLimit()
        limit.record(headers: headers(overall: "10,1999", read: "0,0"), at: now)
        let tomorrow = StravaRateLimit.nextMidnightUTC(after: now).addingTimeInterval(60)
        #expect(limit.earliestStart(for: .write, at: tomorrow) == tomorrow)
        #expect(limit.overall.dailyUsed == 0)
    }

    @Test("a 429 blocks everything until the next quarter hour")
    func throttledShortTerm() {
        var limit = StravaRateLimit()
        limit.recordThrottled(headers: headers(overall: "200,900", read: "50,300"), at: now)
        let boundary = StravaRateLimit.nextQuarterHour(after: now)
        #expect(limit.blockedUntil == boundary)
        #expect(limit.earliestStart(for: .write, at: now) == boundary)
    }

    @Test("a 429 on the daily limit blocks until midnight UTC")
    func throttledDaily() {
        var limit = StravaRateLimit()
        limit.recordThrottled(headers: headers(overall: "20,2000", read: "0,0"), at: now)
        #expect(limit.blockedUntil == StravaRateLimit.nextMidnightUTC(after: now))
    }

    @Test("window boundaries fall on the quarter hour and midnight UTC")
    func boundaries() {
        #expect(StravaRateLimit.nextQuarterHour(after: now).timeIntervalSince(now) == 8 * 60)
        let exact = Date(timeIntervalSince1970: 1_791_367_200)   // 10:00:00Z
        #expect(StravaRateLimit.nextQuarterHour(after: exact).timeIntervalSince(exact) == 15 * 60,
                "a boundary itself starts a fresh window, so the next one is a full quarter away")
        #expect(StravaRateLimit.nextMidnightUTC(after: now).timeIntervalSince1970
                .truncatingRemainder(dividingBy: 86_400) == 0)
    }

    @Test("malformed headers are ignored rather than zeroing the count")
    func malformedHeaders() {
        var limit = StravaRateLimit()
        limit.record(headers: headers(overall: "50,500", read: "10,100"), at: now)
        limit.record(headers: ["X-RateLimit-Usage": "garbage", "X-RateLimit-Limit": "200"], at: now)
        #expect(limit.overall.shortTermUsed == 50)
    }
}
