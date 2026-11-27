import CoreGraphics
import Foundation
import Network
import Synchronization
import Testing
@testable import AgentNotch

struct StressTests {
    private struct RNG {
        var state: UInt64 = 0x221efadc
        mutating func index(_ count: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(count))
        }
    }

    @Test func seededQuotaMutationsKeepWindowInvariants() {
        let started = ContinuousClock.now
        let model = """
        {"userStatus":{"email":"synthetic@example.invalid","cascadeModelConfigData":{"clientModelConfigs":[
        {"label":"Gemini","quotaInfo":{"remainingFraction":0.1785842,"resetTime":"2026-11-27T14:12:16Z"}},
        {"label":"Claude","quotaInfo":{"remainingFraction":0.66096336}}]}}}
        """
        let replacements = ["null", "true", "{}", "[]", "1e309", "1e308", "\"NaN\"", "\"Inf\"", "\"0.5\"",
                            "-0.1", "1.1", "\"Gemini 🌌\u{202E}\"", "{\"seconds\":1e308,\"nanos\":1}"]
        let needles = ["0.1785842", "0.66096336", "\"2026-11-27T14:12:16Z\"", "\"Gemini Models\"", "\"Claude\"",
                       "\"response\"", "\"remainingFraction\"", "\"buckets\"", "\"quotaInfo\""]
        var rng = RNG()
        var accepted = 0
        for i in 0..<4000 {
            let grouped = i.isMultiple(of: 2)
            var json = grouped ? AntigravityTests.liveSummary : model
            for _ in 0...rng.index(3) {
                let needle = needles[rng.index(needles.count)]
                json = json.replacingOccurrences(of: needle, with: replacements[rng.index(replacements.count)])
            }
            if let snapshot = try? AntigravityQuota.parse(Data(json.utf8), grouped: grouped) {
                accepted += 1
                assertWindows(snapshot)
            }
        }
        let bucket = #"{"bucketId":"weekly","remainingFraction":0.5}"#
        let buckets = Array(repeating: bucket, count: 10_000).joined(separator: ",")
        let huge = """
        {"groups":[{"displayName":"Gemini\(String(repeating: "🌌", count: 20_000))","buckets":[\(buckets)]},
        {"displayName":"Gemini","buckets":[\(bucket)]}]}
        """
        if let snapshot = try? AntigravityQuota.parse(Data(huge.utf8), grouped: true) { assertWindows(snapshot) }
        let nested = String(repeating: "[", count: 2000) + "null" + String(repeating: "]", count: 2000)
        #expect(throws: UsageProviderError.self) { try AntigravityQuota.parse(Data(nested.utf8), grouped: true) }
        #expect(accepted > 1000)
        #expect(ContinuousClock.now - started < .seconds(12))
    }

    private func assertWindows(_ snapshot: ProviderSnapshot) {
        let ids = snapshot.windows.compactMap { Int($0.id) }
        #expect(ids.count == snapshot.windows.count && ids.count <= 4)
        #expect(ids == Array(Set(ids)).sorted() && ids.allSatisfy { (0...3).contains($0) })
        #expect(snapshot.windows.allSatisfy {
            (0...1).contains($0.usedFraction) && ($0.resetsAt?.timeIntervalSince1970.isFinite ?? true)
        })
    }

    private static let executable = "/Applications/Antigravity.app/Contents/Resources/Language Tools/language_server"

    @Test func largeDiscoveryRejectsUnownedPortsAndAvoidsRepeatedSubprocesses() {
        let started = ContinuousClock.now
        let calls = Mutex(0)
        var discovery = AntigravityDiscovery()
        discovery.files = { _ in
            (0..<1000).map { URL(fileURLWithPath: "/synthetic/hub_\($0).json") }
        }
        discovery.read = { url in
            let index = Int(url.deletingPathExtension().lastPathComponent.dropFirst(4)) ?? 0
            switch index {
            case 0: return Data("invalid".utf8)
            case 1: return Data(#"{"pid":90,"httpPort":5000,"csrfToken":"stale"}"#.utf8)
            case 2: return Data(#"{"pid":91,"httpPort":5000,"csrfToken":"wrong-owner"}"#.utf8)
            case 3:
                return Data("""
                {"pid":42,"httpPort":5000,"csrfToken":"\(String(repeating: "A", count: 5000))"}
                """.utf8)
            case 999: return Data(#"{"pid":42,"httpPort":5000,"csrfToken":"valid"}"#.utf8)
            default: return Data(#"{"pid":42,"httpPort":5001,"csrfToken":"wrong-port"}"#.utf8)
            }
        }
        discovery.alive = { $0 != 90 }
        discovery.run = { tool, args in
            calls.withLock { $0 += 1 }
            if tool.contains("lsof") { return "p42\nn[::1]:5001\nn127.0.0.1:5000\nn*:5000\nn192.168.0.1:5002" }
            if args.contains("91") { return "91 \(getuid()) /tmp/language_server --csrf_token wrong" }
            if args.contains("42") { return " 42\t\(getuid()) \(Self.executable) --csrf_token valid --extension_server_port 5001" }
            return (100..<5100).map { "\($0) /usr/bin/sleep" }.joined(separator: "\n")
                + "\n\t42   \(Self.executable)\n42 \(Self.executable)"
        }
        #expect(discovery.hub()?.token == "valid")
        #expect(calls.withLock { $0 } == 3)
        let endpoints = discovery.processEndpoints()
        #expect(endpoints.count == 1 && endpoints.first?.token == "valid" && endpoints.first?.port == 5000)
        #expect(calls.withLock { $0 } == 6)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func cancelledDiscoveryNeverInvokesTheRunner() async {
        let calls = Mutex(0)
        var discovery = AntigravityDiscovery()
        discovery.run = { _, _ in calls.withLock { $0 += 1 }; return "" }
        let fixture = discovery
        let stream = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream.stream {}
            return fixture.processEndpoints()
        }
        task.cancel()
        stream.continuation.finish()
        #expect(await task.value.isEmpty)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func timedOutSubprocessReturnsPromptly() {
        let start = ContinuousClock.now
        #expect(LocalSecurityTool.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
                                      options: .init(timeout: 0.05, maxBytes: 4096)) == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test @MainActor func layoutMatrixFitsPanelsAndSeparatesCells() {
        let defaults = UserDefaults(suiteName: "StressTests.layout.\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults, loginItemEnabled: false)
        let model = NotchViewModel(preferences: preferences, store: UsageStore(providers: []))
        for count in 0...4 {
            preferences.usageAccessProviders = Set(ProviderID.allCases.prefix(count))
            for edge in NotchEdge.allCases {
                preferences.notchEdge = edge
                for visibility in NotchVisibility.allCases {
                    preferences.notchVisibility = visibility
                    model.visibilityChanged()
                    let layout = NotchLayout(edge: edge, cells: model.providers.count, isExpanded: model.isExpanded,
                                             tooltipHeight: NotchMetrics.tooltipMaxHeight)
                    let frame = CGRect(origin: .zero, size: layout.panelSize)
                    for screen in [CGSize(width: 1280, height: 800), CGSize(width: 1440, height: 900)] {
                        #expect(frame.width > 0 && frame.height > 0)
                        #expect(CGRect(origin: .zero, size: screen).contains(frame))
                    }
                    for i in 0..<count {
                        #expect(frame.contains(layout.tooltipHotRect(for: i)))
                        #expect(!layout.tooltipRect(for: i).intersects(layout.bodyRect))
                        for j in 0..<i {
                            #expect(layout.cellRect(i).intersection(layout.cellRect(j)).isEmpty)
                        }
                    }
                }
            }
        }
    }

    @Test @MainActor func fourGrantsKeepIndependentGenerations() throws {
        let coordinator = UsageAccessGrantCoordinator()
        for _ in 0..<200 {
            let grants = try ProviderID.allCases.map { id in (id, try #require(coordinator.begin(id))) }
            coordinator.cancel(.antigravity)
            for (id, generation) in grants {
                #expect(coordinator.complete(id, generation: generation) == (id != .antigravity))
                let next = try #require(coordinator.begin(id))
                #expect(!coordinator.complete(id, generation: generation))
                #expect(coordinator.complete(id, generation: next))
            }
            #expect(coordinator.approving.isEmpty)
        }
    }
}

extension StressTests {
    private final class LoopbackServer: Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "StressTests.loopback")
        let connections = Mutex<[NWConnection]>([])

        init(reply: @escaping @Sendable (NWConnection) -> Void) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connections.withLock { $0.append(connection) }
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                    reply(connection)
                }
            }
        }

        func start() async throws -> Int {
            let pending = AsyncThrowingStream<Int, Error>.makeStream()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener.port {
                        pending.continuation.yield(Int(port.rawValue))
                    }
                    pending.continuation.finish()
                case .failed(let error): pending.continuation.finish(throwing: error)
                case .cancelled: pending.continuation.finish()
                default: break
                }
            }
            listener.start(queue: queue)
            for try await port in pending.stream { return port }
            throw CancellationError()
        }

        func stop() {
            listener.cancel()
            connections.withLock { connections in
                for connection in connections { connection.cancel() }
                connections.removeAll()
            }
        }
    }

    private static func send(_ data: Data, via connection: NWConnection, final: Bool = true) {
        connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage,
                        isComplete: final, completion: .contentProcessed { _ in })
    }

    @Test(arguments: [401, 404, 500, 307, 200])
    func rejectsHTTPFailuresRedirectAndWrongContentType(_ code: Int) async throws {
        let unexpected = Mutex(0)
        let destination = try LoopbackServer { _ in unexpected.withLock { $0 += 1 } }
        defer { destination.stop() }
        let destinationPort = try await destination.start()
        let origin = try LoopbackServer { connection in
            let reply = "HTTP/1.1 \(code) Test\r\nLocation: http://127.0.0.1:\(destinationPort)/no\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
            Self.send(Data(reply.utf8), via: connection)
        }
        defer { origin.stop() }
        let port = try await origin.start()
        let endpoint = AntigravityEndpoint(port: port, token: "synthetic", plainHTTP: true)
        await #expect(throws: UsageProviderError.self) { try await endpoint.post(.summary) }
        #expect(unexpected.withLock { $0 } == 0)
    }

    @Test func responseSizeCapRejectsAnnouncedAndUnannouncedOversize() async throws {
        for announced in [true, false] {
            let server = try LoopbackServer { connection in
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n"
                    + (announced ? "Content-Length: 20971520\r\n" : "") + "\r\n"
                var bytes = Data(header.utf8)
                if !announced { bytes.append(Data(repeating: 32, count: AntigravityEndpoint.maxResponseBytes + 1)) }
                Self.send(bytes, via: connection)
            }
            defer { server.stop() }
            let port = try await server.start()
            let endpoint = AntigravityEndpoint(port: port, token: "synthetic", plainHTTP: true)
            await #expect(throws: UsageProviderError.self) { try await endpoint.post(.summary) }
        }
    }

    @Test(arguments: [false, true])
    func idleAndSlowDripResponsesExpire(_ drip: Bool) async throws {
        let server = try LoopbackServer { connection in
            if drip {
                Self.send(Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 99\r\n\r\n{".utf8),
                          via: connection, final: false)
                for index in 1...12 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(80 * index)) {
                        Self.send(Data([32]), via: connection, final: false)
                    }
                }
            }
        }
        defer { server.stop() }
        let port = try await server.start()
        let endpoint = AntigravityEndpoint(port: port, token: "synthetic", plainHTTP: true)
        let start = ContinuousClock.now
        do {
            _ = try await endpoint.post(.summary) {
                $0.timeoutIntervalForRequest = 0.3
                $0.timeoutIntervalForResource = 0.7
            }
            Issue.record("Incomplete response was accepted")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func invalidJSONFromLoopbackIsRejectedByParser() async throws {
        let server = try LoopbackServer { connection in
            Self.send(Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1\r\n\r\n{".utf8),
                      via: connection)
        }
        defer { server.stop() }
        let port = try await server.start()
        let endpoint = AntigravityEndpoint(port: port, token: "synthetic", plainHTTP: true)
        let body = try await endpoint.post(.summary)
        #expect(throws: UsageProviderError.self) { try AntigravityQuota.parse(body, grouped: true) }
    }
}

extension StressTests {
    private actor HeldProvider: UsageProvider {
        nonisolated let id = ProviderID.antigravity
        private let entered: AsyncStream<Void>.Continuation
        let starts: AsyncStream<Void>
        private var pending: [CheckedContinuation<ProviderSnapshot, Never>] = []

        init() {
            let stream = AsyncStream<Void>.makeStream()
            starts = stream.stream
            entered = stream.continuation
        }

        func fetch() async throws -> ProviderSnapshot {
            await withCheckedContinuation { continuation in
                pending.append(continuation)
                entered.yield(())
            }
        }

        func completeAll() {
            for continuation in pending {
                continuation.resume(returning: ProviderSnapshot(
                    id: id, account: nil, plan: nil, windows: [], fetchedAt: .now
                ))
            }
            pending.removeAll()
            entered.finish()
        }
    }

    @Test @MainActor func twoHundredRevocationsDiscardEveryInFlightReading() async {
        let domain = "StressTests.switches.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults, loginItemEnabled: false)
        let provider = HeldProvider()
        let store = UsageStore(providers: [provider], defaults: defaults, enabledProviders: [], savedReadings: defaults)
        let model = NotchViewModel(preferences: preferences, store: store)
        var started = await provider.starts.makeAsyncIterator()
        for _ in 0..<200 {
            preferences.setUsageAccess(.antigravity, allowed: true)
            store.setEnabledProviders(preferences.usageAccessProviders)
            _ = await started.next()
            preferences.setUsageAccess(.antigravity, allowed: false)
            store.setEnabledProviders(preferences.usageAccessProviders)
        }
        await provider.completeAll()
        // All the continuations have been resumed before this actor yields.
        for _ in 0..<10 { await Task.yield() }
        #expect(model.providers.isEmpty)
        #expect(store.status(for: .antigravity) == .failed(UsageStore.disconnectedStatus))
        #expect(!store.isRefreshing)
        #expect(defaults.data(forKey: UsageStore.savedReadingsKey) == Data("{}".utf8))
    }

    @Test @MainActor func hubRecoveryBypassesMissBackoffAndAccountSwitchHasNoTransition() async throws {
        let port = Mutex(4100)
        let scans = Mutex(0)
        var discovery = AntigravityDiscovery()
        discovery.files = { _ in port.withLock { $0 == 0 ? [] : [URL(fileURLWithPath: "/fake/hub_live.json")] } }
        discovery.read = { _ in port.withLock { Data("""
        {"pid":42,"httpPort":\($0),"csrfToken":"synthetic"}
        """.utf8) } }
        discovery.alive = { $0 == 42 }
        discovery.run = { tool, args in
            if tool.contains("lsof") { return port.withLock { "n127.0.0.1:\($0)" } }
            if args.contains("42") { return "42 \(getuid()) \(Self.executable)" }
            scans.withLock { $0 += 1 }
            return ""
        }
        let launch = Mutex(false)
        var provider = AntigravityProvider(discovery: discovery) { endpoint, method in
            guard method == .status else { throw UsageProviderError.unavailable("No grouped quota") }
            let account = endpoint.port == 4100 ? "first@example.invalid" : "second@example.invalid"
            let remaining = endpoint.port == 4100 ? 0.5 : 0
            return Data("""
            {"userStatus":{"email":"\(account)","cascadeModelConfigData":{"clientModelConfigs":[
            {"label":"Gemini","quotaInfo":{"remainingFraction":\(remaining)}}]}}}
            """.utf8)
        }
        provider.appIsRunning = { launch.withLock { $0 } }
        let domain = "StressTests.recovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = UsageStore(providers: [provider], defaults: defaults, savedReadings: defaults)
        func refresh() async {
            store.refresh(.antigravity)
            while store.isRefreshing { await Task.yield() }
        }
        await refresh()
        #expect(store.status(for: .antigravity).snapshot?.account == "first@example.invalid")
        port.withLock { $0 = 0 }
        for _ in 0..<10 { await refresh() }
        #expect(scans.withLock { $0 } == 1)
        #expect(store.status(for: .antigravity).isStale)
        #expect(store.awaitingOwnerTool.contains(.antigravity))
        launch.withLock { $0 = true }
        await refresh()
        #expect(scans.withLock { $0 } == 2)
        launch.withLock { $0 = false }
        port.withLock { $0 = 4200 }
        await refresh()
        let snapshot = try #require(store.status(for: .antigravity).snapshot)
        #expect(!store.status(for: .antigravity).isStale)
        #expect(snapshot.account == "second@example.invalid")
        #expect(snapshot.headline?.usedFraction == 1)
        #expect(store.limitEventRevision == 0)
        let data = try #require(defaults.data(forKey: UsageStore.savedReadingsKey))
        #expect(!String(decoding: data, as: UTF8.self).contains("@example.invalid"))
        let saved = try JSONDecoder().decode([String: ProviderSnapshot].self, from: data)
        #expect(saved["antigravity"]?.accountBinding == nil)
    }
}

extension StressTests {
    @Test func realTLSFailureFallsBackToHTTPOnSameLoopbackPort() async throws {
        let summary = AntigravityTests.liveSummary
        let server = try LoopbackServer { connection in
            // A plain HTTP listener cannot speak TLS. Its first bytes trigger the HTTPS failure.
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(summary.utf8.count)\r\n\r\n\(summary)"
            Self.send(Data(reply.utf8), via: connection)
        }
        defer { server.stop() }
        let port = try await server.start()
        var discovery = AntigravityDiscovery()
        discovery.files = { _ in [URL(fileURLWithPath: "/fake/hub_tls.json")] }
        discovery.read = { _ in Data("""
        {"pid":42,"httpPort":\(port),"csrfToken":"synthetic"}
        """.utf8) }
        discovery.alive = { $0 == 42 }
        discovery.run = { tool, _ in
            tool.contains("lsof") ? "n127.0.0.1:\(port)" : "42 \(getuid()) \(Self.executable)"
        }
        let schemes = Mutex<[Bool]>([])
        let provider = AntigravityProvider(discovery: discovery) { endpoint, method in
            #expect(endpoint.port == port)
            schemes.withLock { $0.append(endpoint.plainHTTP) }
            return try await endpoint.post(method)
        }
        #expect(try await provider.fetch().headline?.label == "Gemini session")
        #expect(schemes.withLock { $0 } == [false, true])
    }
}
