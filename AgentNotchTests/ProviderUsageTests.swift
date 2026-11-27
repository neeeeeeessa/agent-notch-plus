import Foundation
import Testing

@testable import AgentNotch

struct ProviderUsageTests {
    @Test func claudeCodeBlobConvertsMillisecondExpiry() throws {
        let blob = Data(
            """
            {"claudeAiOauth":{"accessToken":"tok","refreshToken":"ref","expiresAt":1788542453069}}
            """.utf8)
        let session = try #require(ClaudeOAuthSession.fromClaudeCodeBlob(blob))
        #expect(session.accessToken == "tok")
        #expect(session.refreshToken == "")
        #expect(abs(session.expiresAt - 1_788_542_453.069) < 0.01)
    }

    @Test func claudeCodeBlobRejectsMissingToken() {
        let blob = Data(#"{"claudeAiOauth":{"expiresAt":1788542453069}}"#.utf8)
        #expect(ClaudeOAuthSession.fromClaudeCodeBlob(blob) == nil)
    }

    @Test func claudeUsageJSONBuildsSessionAndWeeklyWindows() {
        let json: [String: Any] = [
            "five_hour": [
                "utilization": 2.0,
                "resets_at": "2026-09-04T12:09:59.972355+00:00",
            ],
            "seven_day": [
                "utilization": 18.0,
                "resets_at": "2026-09-07T19:59:59.972383+00:00",
            ],
            "limits": [
                [
                    "kind": "weekly_scoped",
                    "percent": 5,
                    "scope": ["model": ["display_name": "Sonnet"]],
                ]
            ],
        ]
        let windows = ClaudeOAuthProvider().windows(from: json)
        #expect(windows.map(\.id) == ["session", "weekly", "weekly_sonnet"])
        #expect(windows[0].usedFraction == 0.02)
        #expect(windows[1].usedFraction == 0.18)
        #expect(windows[2].usedFraction == 0.05)
        #expect(windows[2].label == "Sonnet")
    }

    @Test func claudeUsageJSONWithoutBucketsIsEmpty() {
        #expect(ClaudeOAuthProvider().windows(from: [:]).isEmpty)
    }

    @Test func codexRateLimitsBuildPrimaryAndSecondaryWindows() throws {
        let limits: [String: Any] = [
            "plan_type": "plus",
            "primary": [
                "used_percent": 1.0,
                "window_minutes": 300,
                "resets_at": 1_788_040_219.0,
            ],
            "secondary": [
                "used_percent": 0.0,
                "window_minutes": 10_080,
                "resets_at": 1_788_627_019.0,
            ],
        ]
        let snapshot = try CodexLocalProvider().snapshot(from: limits)
        #expect(snapshot.id == .codex)
        #expect(snapshot.plan == "Plus")
        #expect(snapshot.windows.map(\.label) == ["Current session", "Weekly limit"])
        #expect(snapshot.windows[0].usedFraction == 0.01)
        #expect(snapshot.windows[1].usedFraction == 0)
    }

    @Test func codexAcceptsWindowDurationMins() {
        let window = CodexLocalProvider().window(
            id: "primary",
            from: ["used_percent": 7.0, "window_duration_mins": 10_080]
        )
        #expect(window?.label == "Weekly limit")
        #expect(window?.usedFraction == 0.07)
    }

    @Test func codexFindsRateLimitsInJsonl() {
        let line = """
            {"payload":{"type":"token_count","rate_limits":{"plan_type":"plus","primary":{"used_percent":3,"window_minutes":300}}}}
            """
        let limits = CodexLocalProvider().rateLimits(in: Data((line + "\n").utf8))
        #expect(limits?["plan_type"] as? String == "plus")
    }

    @Test func authTokenReadsAccessTokenOrApiKey() {
        let provider = CodexLocalProvider()
        #expect(
            provider.authToken(in: Data(#"{"tokens":{"access_token":"aaa"}}"#.utf8)) == "aaa")
        #expect(provider.authToken(in: Data(#"{"OPENAI_API_KEY":"sk"}"#.utf8)) == "sk")
        #expect(provider.authToken(in: Data("{}".utf8)) == nil)
    }

    @Test func codexLiveUsageJSONBuildsWindows() throws {
        let json: [String: Any] = [
            "plan_type": "plus",
            "rate_limit": [
                "allowed": true,
                "primary_window": [
                    "used_percent": 12,
                    "limit_window_seconds": 18_000,
                    "reset_at": 2_000_000_000,
                ],
                "secondary_window": [
                    "used_percent": 4,
                    "limit_window_seconds": 604_800,
                    "reset_at": 2_000_100_000,
                ],
            ],
        ]
        let snapshot = try CodexLocalProvider().snapshot(from: json)
        #expect(snapshot.plan == "Plus")
        #expect(snapshot.windows.map(\.label) == ["Current session", "Weekly limit"])
        #expect(snapshot.windows[0].usedFraction == 0.12)
        #expect(snapshot.windows[1].usedFraction == 0.04)
    }

    @Test func authAccountIDReadsNestedAccount() {
        let blob = Data(#"{"tokens":{"access_token":"aaa","account_id":"acct_1"}}"#.utf8)
        #expect(CodexLocalProvider().authAccountID(in: blob) == "acct_1")
    }

    @Test func codexUsageParsesSummaryResetCountAndDetailFetchPolicy() throws {
        let provider = CodexLocalProvider()
        let withResets: [String: Any] = [
            "plan_type": "prolite",
            "rate_limit": [
                "secondary_window": [
                    "used_percent": 7,
                    "limit_window_seconds": 604_800,
                ]
            ],
            "rate_limit_reset_credits": ["available_count": 4],
        ]
        let snapshot = try provider.snapshot(from: withResets)
        #expect(snapshot.resetCredits?.availableCount == 4)
        #expect(snapshot.resetCredits?.items.isEmpty == true)
        #expect(provider.shouldFetchResetCreditDetails(in: withResets))

        let zeroResets: [String: Any] = [
            "rate_limit_reset_credits": ["available_count": 0]
        ]
        #expect(!provider.shouldFetchResetCreditDetails(in: zeroResets))
        #expect(provider.shouldFetchResetCreditDetails(in: [:]))
    }

    @Test func codexResetCreditsParserFiltersSortsAndFlagsExpiringSoon() throws {
        let now = try #require(JSONDate.parse("2026-11-27T16:00:00Z"))
        let payload: [String: Any] = [
            "available_count": 4,
            "credits": [
                ["id": "c4", "title": "Full reset", "status": "available", "expires_at": "2026-12-26T06:21:00Z"],
                ["id": "c-used", "title": "Full reset", "status": "redeemed", "expires_at": "2026-11-29T10:00:00Z"],
                ["id": "c-old", "title": "Full reset", "status": "available", "expires_at": "2026-11-26T10:00:00Z"],
                ["id": "c1", "reset_type": "full", "status": "available", "expires_at": "2026-11-30T20:29:00Z"],
                ["id": "c2", "title": "Full reset", "status": "available", "expires_at": "2026-12-01T22:56:00Z"],
                ["id": "c3", "reset_type": "weekly", "status": "available", "expires_at": "2026-12-12T22:52:00Z"],
            ],
        ]
        let credits = try #require(CodexLocalProvider().parseResetCredits(from: payload, now: now))
        #expect(credits.activeCount(now: now) == 4)
        #expect(credits.items.map(\.id) == ["c1", "c2", "c3", "c4"])
        #expect(credits.items.map(\.label) == ["Full reset", "Full reset", "Weekly reset", "Full reset"])
        #expect(credits.hasExpiringSoon(now: now))
        #expect(ResetCredits.isExpiringSoon(credits.items[0].expiresAt, now: now))
        #expect(ResetCredits.isExpiringSoon(credits.items[1].expiresAt, now: now))
        #expect(!ResetCredits.isExpiringSoon(credits.items[2].expiresAt, now: now))
        #expect(ResetCreditsText.relativeRemaining(until: credits.items[0].expiresAt!, now: now) == "3d")
        #expect(ResetCreditsText.relativeRemaining(until: credits.items[1].expiresAt!, now: now) == "4d")
    }

    @Test func claudeCedarEmberGrantsParseAndFilterCorrectly() throws {
        let now = try #require(JSONDate.parse("2026-11-27T16:00:00Z"))
        let root: [String: Any] = [
            "cedar_ember": [
                "eligible": true,
                "grants": [
                    [
                        "id": "g-later",
                        "label": "Full reset",
                        "resets_left": 2,
                        "ends_at": "2026-12-15T12:00:00Z",
                        "paused": false,
                    ],
                    [
                        "id": "g-paused",
                        "type": "session",
                        "resets_left": 1,
                        "ends_at": "2026-11-29T12:00:00Z",
                        "paused": true,
                    ],
                    [
                        "id": "g-expired",
                        "type": "weekly",
                        "resets_left": 1,
                        "ends_at": "2026-11-20T12:00:00Z",
                        "paused": false,
                    ],
                    [
                        "id": "g-zero",
                        "type": "full",
                        "resets_left": 0,
                        "ends_at": "2026-12-01T12:00:00Z",
                        "paused": false,
                    ],
                    [
                        "id": "g-soon",
                        "gives_back_weekly": true,
                        "resets_left": 1,
                        "ends_at": "2026-11-30T18:00:00Z",
                        "paused": false,
                    ],
                ],
            ]
        ]
        let credits = try #require(ClaudeOAuthProvider().resetCredits(from: root, now: now))
        #expect(credits.activeCount(now: now) == 3)
        #expect(credits.items.map(\.id) == ["g-soon", "g-later"])
        #expect(credits.items.map(\.label) == ["Fable reset", "Full reset"])
        #expect(credits.items.map(\.count) == [1, 2])
        #expect(credits.hasExpiringSoon(now: now))

        let noGrant: [String: Any] = ["cedar_ember": ["eligible": false, "ineligible_reason": "no_grant", "grants": []]]
        #expect(ClaudeOAuthProvider().resetCredits(from: noGrant, now: now)?.activeCount(now: now) == 0)

        let surfaceRejected: [String: Any] = ["cedar_ember": ["eligible": false, "ineligible_reason": "surface", "grants": []]]
        #expect(ClaudeOAuthProvider().resetCredits(from: surfaceRejected, now: now) == nil)
    }

}
