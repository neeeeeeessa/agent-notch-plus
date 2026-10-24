import Darwin
import Foundation
import Security
import os

/// RAM-only approved sign-in. One generation per service. Tests use a fresh instance.
/// The process cache dies on exit. Discarded bytes are not securely erased.
nonisolated final class KeychainSessionStore: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        var service: String
        var account: String
        var dataProtection: Bool
    }

    /// Identifies one in-flight grant. A commit or failure is a no-op when it does not match.
    struct GrantTicket: Sendable, Equatable {
        fileprivate var service: String
        fileprivate var generation: UInt
    }

    private struct Slot {
        var generation: UInt = 0
        var pending = false
        var payload: Data?
        var expiresAt: Date?
        var account = ""
        var dataProtection = false
    }

    private let lock = NSLock()
    private var slots: [String: Slot] = [:]
    /// Original OS read still inside `SecItemCopyMatching` or its completion. Separate from the epoch.
    private var activeReads: [String: UInt] = [:]

    /// Drops any approved payload, bumps the epoch, and marks the service pending.
    /// Refuses while this service's OS read is still active, including after the epoch was invalidated.
    func beginGrant(service: String) -> GrantTicket? {
        lock.lock()
        defer { lock.unlock() }
        if activeReads[service] != nil { return nil }
        var slot = slots[service] ?? Slot()
        if slot.pending { return nil }
        slot.generation &+= 1
        slot.pending = true
        slot.payload = nil
        slot.expiresAt = nil
        slot.account = ""
        slot.dataProtection = false
        slots[service] = slot
        activeReads[service] = slot.generation
        return GrantTicket(service: service, generation: slot.generation)
    }

    /// Sanitizes first. Writes only when this ticket is still the pending generation.
    /// Releases the matching OS ticket on success, staleness, or sanitization failure.
    func completeGrant(
        _ ticket: GrantTicket,
        raw: Data,
        account: String?,
        dataProtection: Bool,
        now: Date
    ) throws {
        let sanitized: KeychainCredentialSanitizer.Sanitized
        do {
            sanitized = try KeychainCredentialSanitizer.sanitize(service: ticket.service, raw: raw, now: now)
        } catch {
            releaseActiveRead(ticket)
            throw error
        }
        lock.lock()
        defer { lock.unlock() }
        releaseActiveReadLocked(ticket)
        guard var slot = slots[ticket.service], slot.pending, slot.generation == ticket.generation else {
            throw UsageProviderError.needsAuth(Keychain.reconnectMessage)
        }
        slot.pending = false
        slot.payload = sanitized.payload
        slot.expiresAt = sanitized.expiresAt
        slot.account = account ?? ""
        slot.dataProtection = dataProtection
        slots[ticket.service] = slot
    }

    /// Clears a still-current failed grant. A stale ticket does not touch a newer payload.
    /// Releases the matching OS ticket when the original call returns.
    func failGrant(_ ticket: GrantTicket) {
        lock.lock()
        defer { lock.unlock() }
        releaseActiveReadLocked(ticket)
        guard var slot = slots[ticket.service], slot.generation == ticket.generation else { return }
        slot.pending = false
        slot.payload = nil
        slot.expiresAt = nil
        slots[ticket.service] = slot
    }

    /// Bumps a pending epoch immediately. Does not remove the active OS ticket.
    /// An approved payload from another generation stays.
    func invalidatePending(service: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var slot = slots[service], slot.pending else { return }
        slot.generation &+= 1
        slot.pending = false
        slot.payload = nil
        slot.expiresAt = nil
        slots[service] = slot
    }

    private func releaseActiveRead(_ ticket: GrantTicket) {
        lock.lock()
        defer { lock.unlock() }
        releaseActiveReadLocked(ticket)
    }

    private func releaseActiveReadLocked(_ ticket: GrantTicket) {
        if activeReads[ticket.service] == ticket.generation {
            activeReads[ticket.service] = nil
        }
    }

    /// Immediate revoke. Does not take the OS-read lock or clear the active OS ticket. Stale completions cannot commit afterward.
    func discard(service: String) {
        lock.lock()
        defer { lock.unlock() }
        var slot = slots[service] ?? Slot()
        slot.generation &+= 1
        slot.pending = false
        slot.payload = nil
        slot.expiresAt = nil
        slots[service] = slot
    }

    /// Synthetic test helper only. Not used on the live grant path.
    func retainApproved(
        service: String,
        account: String?,
        dataProtection: Bool,
        raw: Data,
        now: Date
    ) throws {
        let sanitized = try KeychainCredentialSanitizer.sanitize(service: service, raw: raw, now: now)
        lock.lock()
        defer { lock.unlock() }
        var slot = slots[service] ?? Slot()
        slot.generation &+= 1
        slot.pending = false
        slot.payload = sanitized.payload
        slot.expiresAt = sanitized.expiresAt
        slot.account = account ?? ""
        slot.dataProtection = dataProtection
        slots[service] = slot
    }

    /// RAM lookup for a later silent read. Expired payloads are dropped and reported as a miss.
    func lookupCache(
        service: String,
        account: String?,
        dataProtection: Bool,
        now: Date
    ) -> KeychainCacheLookup {
        guard Keychain.readableServices.contains(service) else { return .miss }
        lock.lock()
        defer { lock.unlock() }
        guard var slot = slots[service] else { return .miss }
        guard slot.account == (account ?? ""), slot.dataProtection == dataProtection else { return .mismatch }
        if slot.pending { return .busy }
        guard let payload = slot.payload else { return .miss }
        if let expiresAt = slot.expiresAt, expiresAt <= now {
            slot.payload = nil
            slot.expiresAt = nil
            slots[service] = slot
            return .miss
        }
        return .hit(payload)
    }

    /// Exact grant match only. Expired entries are dropped. Unknown services return nil.
    func cachedData(
        service: String,
        account: String?,
        dataProtection: Bool,
        now: Date
    ) throws -> Data? {
        guard Keychain.readableServices.contains(service) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard var slot = slots[service] else {
            throw UsageProviderError.needsAuth(Keychain.reconnectMessage)
        }
        guard slot.account == (account ?? ""), slot.dataProtection == dataProtection else {
            throw UsageProviderError.needsAuth(Keychain.reconnectMessage)
        }
        guard let payload = slot.payload, !slot.pending else {
            throw UsageProviderError.needsAuth(Keychain.reconnectMessage)
        }
        if let expiresAt = slot.expiresAt, expiresAt <= now {
            slot.payload = nil
            slot.expiresAt = nil
            slots[service] = slot
            throw UsageProviderError.needsAuth(Keychain.reconnectMessage)
        }
        return payload
    }
}

nonisolated enum KeychainCredentialSanitizer {
    struct Sanitized: Sendable {
        var payload: Data
        var expiresAt: Date?
    }

    /// Rebuilds a parser-compatible blob that keeps only the approved fields.
    nonisolated static func sanitize(service: String, raw: Data, now: Date) throws -> Sanitized {
        switch service {
        case ClaudeOAuthStore.claudeCodeService:
            guard let session = ClaudeOAuthSession.fromClaudeCodeBlob(raw),
                !session.accessToken.isEmpty,
                session.expires > now
            else {
                throw UsageProviderError.needsAuth("Existing sign-in was not found")
            }
            let payload = try JSONSerialization.data(withJSONObject: [
                "claudeAiOauth": [
                    "accessToken": session.accessToken,
                    "expiresAt": session.expiresAt,
                ],
            ])
            return Sanitized(payload: payload, expiresAt: session.expires)
        case "Codex Auth":
            guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                let tokens = json["tokens"] as? [String: Any],
                let accessToken = tokens["access_token"] as? String,
                !accessToken.isEmpty
            else {
                throw UsageProviderError.needsAuth("Existing sign-in was not found")
            }
            var kept: [String: Any] = ["access_token": accessToken]
            if let accountID = tokens["account_id"] as? String, !accountID.isEmpty {
                kept["account_id"] = accountID
            }
            let payload = try JSONSerialization.data(withJSONObject: ["tokens": kept])
            return Sanitized(payload: payload, expiresAt: nil)
        default:
            throw UsageProviderError.unavailable("Keychain service is not allowlisted")
        }
    }
}

nonisolated enum KeychainCacheLookup: Sendable {
    case hit(Data)
    case miss
    case mismatch
    case busy
}

nonisolated enum KeychainDirectOutcome: Sendable {
    case data(Data)
    case missing
    case interactionRefused
    case failed
}

nonisolated enum KeychainAccountResolution: Sendable {
    case unique(String)
    case ambiguous
    case unavailable
}

/// Foreground and background reads for the two allowlisted items.
/// Closures stand in for Security, the Apple tool, and saved consent so tests never touch them.
nonisolated final class KeychainAccessReader: @unchecked Sendable {
    let sessions: KeychainSessionStore
    var isApproved: @Sendable (ProviderID) -> Bool
    var isRefused: @Sendable (ProviderID) -> Bool
    var setRefused: @Sendable (ProviderID, Bool) -> Void
    var directRead: @Sendable (String, String?, Bool, Bool) throws -> KeychainDirectOutcome
    var resolveAccount: @Sendable (String) throws -> KeychainAccountResolution
    var isKeychainUnlocked: @Sendable () -> Bool
    var toolRead: @Sendable (String, String) -> Data?
    var now: @Sendable () -> Date

    init(
        sessions: KeychainSessionStore = KeychainSessionStore(),
        isApproved: @escaping @Sendable (ProviderID) -> Bool,
        isRefused: @escaping @Sendable (ProviderID) -> Bool,
        setRefused: @escaping @Sendable (ProviderID, Bool) -> Void,
        directRead: @escaping @Sendable (String, String?, Bool, Bool) throws -> KeychainDirectOutcome,
        resolveAccount: @escaping @Sendable (String) throws -> KeychainAccountResolution,
        isKeychainUnlocked: @escaping @Sendable () -> Bool,
        toolRead: @escaping @Sendable (String, String) -> Data?,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessions = sessions
        self.isApproved = isApproved
        self.isRefused = isRefused
        self.setRefused = setRefused
        self.directRead = directRead
        self.resolveAccount = resolveAccount
        self.isKeychainUnlocked = isKeychainUnlocked
        self.toolRead = toolRead
        self.now = now
    }

    func data(service: String, account: String?, dataProtection: Bool) throws -> Data? {
        guard let provider = Keychain.provider(for: service) else { return nil }
        guard isApproved(provider), !isRefused(provider) else {
            throw UsageProviderError.needsAuth(Keychain.reconnectMessage)
        }
        switch sessions.lookupCache(
            service: service, account: account, dataProtection: dataProtection, now: now())
        {
        case .hit(let payload):
            return payload
        case .mismatch:
            throw UsageProviderError.needsAuth(Keychain.reconnectMessage)
        case .busy:
            throw UsageProviderError.unavailable(Keychain.grantInProgressMessage)
        case .miss:
            break
        }
        guard let ticket = sessions.beginGrant(service: service) else {
            throw UsageProviderError.unavailable(Keychain.grantInProgressMessage)
        }
        var committed = false
        do {
            let outcome = try directRead(service, account, dataProtection, false)
            switch outcome {
            case .data(let raw):
                let payload = try commit(
                    ticket, raw: raw, account: account, dataProtection: dataProtection)
                committed = true
                return payload
            case .missing:
                throw UsageProviderError.needsAuth("Existing sign-in was not found")
            case .failed:
                throw UsageProviderError.unavailable("keychain read failed")
            case .interactionRefused:
                let payload = try rescue(
                    ticket: ticket,
                    provider: provider,
                    service: service,
                    account: account,
                    dataProtection: dataProtection
                )
                committed = true
                return payload
            }
        } catch {
            if !committed { sessions.failGrant(ticket) }
            throw error
        }
    }

    /// Explicit Settings read. May prompt. A denial is stored and is not retried through the Apple tool.
    func requestForeground(service: String) throws {
        guard let provider = Keychain.provider(for: service) else {
            throw UsageProviderError.unavailable("Keychain service is not allowlisted")
        }
        guard let ticket = sessions.beginGrant(service: service) else {
            throw UsageProviderError.unavailable(Keychain.grantInProgressMessage)
        }
        var committed = false
        do {
            let outcome = try directRead(service, nil, false, true)
            switch outcome {
            case .data(let raw):
                _ = try commit(ticket, raw: raw, account: nil, dataProtection: false)
                committed = true
                setRefused(provider, false)
            case .missing:
                throw UsageProviderError.needsAuth("Existing sign-in was not found")
            case .interactionRefused:
                setRefused(provider, true)
                throw UsageProviderError.needsAuth("macOS refused the keychain read")
            case .failed:
                throw UsageProviderError.unavailable("keychain read failed")
            }
        } catch {
            if !committed { sessions.failGrant(ticket) }
            throw error
        }
    }

    private func rescue(
        ticket: KeychainSessionStore.GrantTicket,
        provider: ProviderID,
        service: String,
        account: String?,
        dataProtection: Bool
    ) throws -> Data? {
        guard isApproved(provider), !isRefused(provider) else {
            sessions.failGrant(ticket)
            throw UsageProviderError.needsAuth(Keychain.reconnectMessage)
        }
        let exact: String?
        if let account, !account.isEmpty {
            exact = account
        } else {
            switch try resolveAccount(service) {
            case .unique(let value) where !value.isEmpty:
                exact = value
            case .unique, .ambiguous, .unavailable:
                exact = nil
            }
        }
        guard let exact else {
            throw UsageProviderError.needsAuth("Existing sign-in was not found")
        }
        guard isKeychainUnlocked() else {
            throw UsageProviderError.needsAuth("macOS refused the keychain read")
        }
        guard isApproved(provider), !isRefused(provider) else {
            throw UsageProviderError.needsAuth(Keychain.reconnectMessage)
        }
        guard let raw = toolRead(service, exact) else {
            throw UsageProviderError.needsAuth("macOS refused the keychain read")
        }
        return try commit(ticket, raw: raw, account: account, dataProtection: dataProtection)
    }

    private func commit(
        _ ticket: KeychainSessionStore.GrantTicket,
        raw: Data,
        account: String?,
        dataProtection: Bool
    ) throws -> Data {
        try sessions.completeGrant(
            ticket, raw: raw, account: account, dataProtection: dataProtection, now: now())
        guard
            case .hit(let payload) = sessions.lookupCache(
                service: ticket.service, account: account, dataProtection: dataProtection, now: now())
        else {
            throw UsageProviderError.needsAuth(Keychain.reconnectMessage)
        }
        return payload
    }
}

/// Newest allowlisted item, chosen from attributes only. No secret is kept here.
///
/// Selection is adapted from Codenotch `KeychainItem.winner` (Copyright (c) 2026 Vinz, MIT;
/// see `AgentNotch/Resources/Codenotch-LICENSE.txt`). One match may be a dictionary or a
/// one-element array. A missing modification date still counts and ranks oldest.
nonisolated enum KeychainItemSelection {
    struct Match: Sendable, Equatable {
        var modifiedAt: Date?
        var persistentRef: Data
        var service: String
        var account: String
    }

    static func newest(from result: Any) -> Match? {
        matches(from: result).max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    static func matches(from result: Any) -> [Match] {
        dictionaries(from: result).compactMap(match(from:))
    }

    /// Every row must carry this same non-empty account. Duplicates of that account stay.
    static func sharedAccount(from result: Any) -> String? {
        let rows = dictionaries(from: result)
        guard !rows.isEmpty else { return nil }
        let accounts = rows.map { account(in: $0) }
        guard let candidate = accounts.first, let account = candidate, !account.isEmpty else { return nil }
        guard accounts.allSatisfy({ $0 == account }) else { return nil }
        return account
    }

    private static func dictionaries(from result: Any) -> [[String: Any]] {
        if let one = dictionary(result) { return [one] }
        guard let rows = result as? [Any] else { return [] }
        return rows.compactMap(dictionary)
    }

    private static func dictionary(_ value: Any) -> [String: Any]? {
        if let row = value as? [String: Any] { return row }
        guard let row = value as? [CFString: Any] else { return nil }
        var copy: [String: Any] = [:]
        for (key, entry) in row {
            copy[key as String] = entry
        }
        return copy
    }

    private static func match(from row: [String: Any]) -> Match? {
        guard let ref = row[kSecValuePersistentRef as String] as? Data, !ref.isEmpty else { return nil }
        return Match(
            modifiedAt: row[kSecAttrModificationDate as String] as? Date,
            persistentRef: ref,
            service: row[kSecAttrService as String] as? String ?? "",
            account: account(in: row) ?? ""
        )
    }

    private static func account(in row: [String: Any]) -> String? {
        guard let account = row[kSecAttrAccount as String] as? String, !account.isEmpty else { return nil }
        return account
    }
}

/// Bounded `/usr/bin/security` read. The password stays in this process.
///
/// Adapted from Codenotch's KeychainSecret (Copyright (c) 2026 Vinz, MIT; see
/// `AgentNotch/Resources/Codenotch-LICENSE.txt`). The tool is used only after a
/// silent refusal, and only with the exact service and exact account.
/// `find-generic-password` cannot take a persistent ref, so it may return an
/// older duplicate. The caller rejects an expired payload and does not keep it.
nonisolated enum LocalSecurityTool {
    struct Options: Sendable {
        var timeout: TimeInterval = 5
        var maxBytes: Int = 256 * 1024
    }

    static func findGenericPassword(service: String, account: String) -> Data? {
        run(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", service, "-a", account, "-w"],
            options: Options()
        )
    }

    /// Nonblocking stdout only. Timeout and overflow send SIGTERM, then SIGKILL.
    /// This never calls `waitUntilExit` or a blocking read.
    static func run(executable: URL, arguments: [String], options: Options = Options()) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let handle = output.fileHandleForReading
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            try? handle.close()
            return nil
        }
        let exited = ExitSignal()
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            try? handle.close()
            return nil
        }
        var collected = Data()
        let deadline = Date().addingTimeInterval(options.timeout)
        var stop: Stop?
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stop == nil {
            if Date() >= deadline {
                stop = .timeout
                break
            }
            var slot = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32((deadline.timeIntervalSinceNow * 1_000).rounded(.up))
            let waited = poll(&slot, 1, max(1, min(remaining, 100)))
            if waited > 0 {
                while true {
                    let count = buffer.withUnsafeMutableBytes { raw -> ssize_t in
                        guard let base = raw.baseAddress else { return -1 }
                        return Darwin.read(fd, base, raw.count)
                    }
                    if count > 0 {
                        collected.append(contentsOf: buffer.prefix(Int(count)))
                        if collected.count > options.maxBytes {
                            collected.removeAll()
                            stop = .overflow
                            break
                        }
                    } else if count == 0 {
                        stop = .eof
                        break
                    } else if errno == EAGAIN || errno == EWOULDBLOCK {
                        break
                    } else {
                        stop = .failed
                        break
                    }
                }
            } else if waited < 0, errno != EINTR {
                stop = .failed
            }
        }
        if stop != .eof {
            reap(process, exited: exited, fd: fd)
            try? handle.close()
            return nil
        }
        if process.isRunning {
            _ = exited.wait(0.25)
        }
        try? handle.close()
        guard !process.isRunning, process.terminationStatus == 0 else {
            if process.isRunning { reap(process, exited: exited, fd: fd) }
            return nil
        }
        while let last = collected.last, last == 0x0A || last == 0x0D {
            collected.removeLast()
        }
        return collected.isEmpty ? nil : collected
    }

    private enum Stop {
        case eof
        case timeout
        case overflow
        case failed
    }

    /// SIGTERM, a short grace, then SIGKILL, then a bounded wait on the termination handler.
    private static func reap(_ process: Process, exited: ExitSignal, fd: Int32) {
        if process.isRunning { process.terminate() }
        var slot = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&slot, 1, 250)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        _ = exited.wait(0.5)
    }
}

private nonisolated final class ExitSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait(_ seconds: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
}

nonisolated enum Keychain: Sendable {
    static let readableServices: Set<String> = ["Claude Code-credentials", "Codex Auth"]
    static let reconnectMessage =
        "Usage access is remembered. Turn it off, then on, to approve this sign-in again."
    static let grantInProgressMessage = "A usage access request is already in progress"

    private static let osLock = NSLock()
    /// Route diagnostic only. The message names the source and never a secret, account, or argument.
    private static let credentialReadLog = Logger(
        subsystem: "local.agentnotch.credentialaccess", category: "readRoute")
    private static let access = KeychainAccessReader(
        isApproved: { provider in
            let allowed = UserDefaults.standard.stringArray(forKey: "usageAccessProviders") ?? []
            return allowed.contains(provider.rawValue)
        },
        isRefused: { provider in
            UserDefaults.standard.bool(forKey: refusalKey(provider))
        },
        setRefused: { provider, refused in
            let key = refusalKey(provider)
            if refused {
                UserDefaults.standard.set(true, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        },
        directRead: { service, account, dataProtection, allowPrompt in
            let outcome = directCopy(
                service: service, account: account, dataProtection: dataProtection, allowPrompt: allowPrompt)
            if case .data = outcome {
                credentialReadLog.notice("Approved local Keychain direct read completed")
            }
            return outcome
        },
        resolveAccount: { service in
            resolveUniqueAccount(service: service)
        },
        isKeychainUnlocked: {
            defaultKeychainUnlocked()
        },
        toolRead: { service, account in
            let data = LocalSecurityTool.findGenericPassword(service: service, account: account)
            if data != nil {
                credentialReadLog.notice("Approved local Keychain tool read completed")
            }
            return data
        }
    )

    static func provider(for service: String) -> ProviderID? {
        switch service {
        case ClaudeOAuthStore.claudeCodeService: .claude
        case "Codex Auth": .codex
        default: nil
        }
    }

    private static func refusalKey(_ provider: ProviderID) -> String {
        "keychainRefused.\(provider.rawValue)"
    }

    static func data(
        service: String,
        account: String? = nil,
        dataProtection: Bool = true
    ) throws -> Data? {
        #if AGENTNOTCH_DEMO
        return nil
        #else
        guard readableServices.contains(service) else { return nil }
        return try access.data(service: service, account: account, dataProtection: dataProtection)
        #endif
    }

    /// One foreground OS read from Settings. The sanitized session stays in RAM for this process only.
    static func requestReadAccess(service: String) throws {
        guard readableServices.contains(service) else {
            throw UsageProviderError.unavailable("Keychain service is not allowlisted")
        }
        #if AGENTNOTCH_DEMO
        throw UsageProviderError.unavailable("Demo mode does not access accounts")
        #else
        try access.requestForeground(service: service)
        #endif
    }

    static func isOverlappingGrant(_ error: Error) -> Bool {
        if case UsageProviderError.unavailable(let message) = error {
            return message == grantInProgressMessage
        }
        return false
    }

    static func clearApprovedSession(provider id: ProviderID) {
        switch id {
        case .claude:
            access.sessions.discard(service: ClaudeOAuthStore.claudeCodeService)
        case .codex:
            access.sessions.discard(service: "Codex Auth")
        case .grokBuild:
            break
        }
    }

    /// Settings disappeared during a foreground grant. A background read for an enabled provider is left alone.
    static func invalidatePendingGrant(provider id: ProviderID) {
        switch id {
        case .claude:
            access.sessions.invalidatePending(service: ClaudeOAuthStore.claudeCodeService)
        case .codex:
            access.sessions.invalidatePending(service: "Codex Auth")
        case .grokBuild:
            break
        }
    }

    static func set(_ data: Data, service: String, account: String) throws {
        _ = (data, service, account)
        throw UsageProviderError.unavailable("Keychain writes are disabled")
    }

    static func delete(service: String, account: String) {
        _ = (service, account)
    }

    /// Silent reads take the process-wide interaction switch. Foreground reads share the lock and may prompt.
    /// Setup failure returns `.failed` and does not call `SecItemCopyMatching`.
    private static func directCopy(
        service: String,
        account: String?,
        dataProtection: Bool,
        allowPrompt: Bool
    ) -> KeychainDirectOutcome {
        osLock.lock()
        defer { osLock.unlock() }
        if allowPrompt {
            return copyData(service: service, account: account, dataProtection: dataProtection, allowPrompt: true)
        }
        var wasAllowed = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&wasAllowed) == errSecSuccess else { return .failed }
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return .failed }
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        return copyData(service: service, account: account, dataProtection: dataProtection, allowPrompt: false)
    }

    /// Attributes for one allowlisted service, then the data for the newest persistent ref.
    private static func copyData(
        service: String,
        account: String?,
        dataProtection: Bool,
        allowPrompt: Bool
    ) -> KeychainDirectOutcome {
        guard readableServices.contains(service) else { return .failed }
        var matching = query(service: service, account: account, dataProtection: dataProtection)
        matching[kSecReturnAttributes] = true
        matching[kSecReturnPersistentRef] = true
        matching[kSecMatchLimit] = kSecMatchLimitAll
        if !allowPrompt {
            matching[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
        }
        var listed: AnyObject?
        let listedStatus = SecItemCopyMatching(matching as CFDictionary, &listed)
        switch listedStatus {
        case errSecItemNotFound:
            return .missing
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            return .interactionRefused
        case errSecSuccess:
            break
        default:
            return .failed
        }
        guard let listed, let match = KeychainItemSelection.newest(from: listed) else { return .missing }
        var item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: match.persistentRef,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if !allowPrompt {
            item[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed }
            return .data(data)
        case errSecItemNotFound:
            return .missing
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            return .interactionRefused
        default:
            return .failed
        }
    }

    /// Service-scoped attribute query. Same-account duplicates are allowed. Different or missing accounts are not.
    private static func resolveUniqueAccount(service: String) -> KeychainAccountResolution {
        osLock.lock()
        defer { osLock.unlock() }
        var wasAllowed = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&wasAllowed) == errSecSuccess else { return .unavailable }
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return .unavailable }
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        guard readableServices.contains(service) else { return .unavailable }
        var matching: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(matching as CFDictionary, &result)
        guard status == errSecSuccess, let result else { return .unavailable }
        guard let account = KeychainItemSelection.sharedAccount(from: result) else { return .ambiguous }
        return .unique(account)
    }

    private static func defaultKeychainUnlocked() -> Bool {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return false }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
        return (status & kSecUnlockStateStatus) == kSecUnlockStateStatus
    }

    private static func query(
        service: String,
        account: String?,
        dataProtection: Bool
    ) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if let account {
            query[kSecAttrAccount] = account
        }
        if dataProtection {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }
}
