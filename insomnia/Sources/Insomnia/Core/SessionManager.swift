import Foundation
import Observation

enum EndReason: String, Sendable {
    case timer
    case user
    case quit
    case batteryFloor
    case thermalCritical
    case backstop
}

/// Owns the session lifecycle: start / extend / end / reconcile.
///
/// Journal-first: every mutation is written to session.json / state.json
/// *before* the matching side effect, and undo always reads state.json from
/// disk, never memory (spec section 8 invariants).
@MainActor
@Observable
final class SessionManager {
    private(set) var session: Session?
    /// Identity captured at launch permits quit before startup reconciliation,
    /// while still refusing cleanup of a journal replaced by another process.
    @ObservationIgnored private var initialSession: Session?
    private(set) var state: RuntimeState
    var config: Config
    /// Minute-granularity remaining time for the popover ("2h 14m").
    private(set) var remainingText: String = ""
    /// Live `H:MM:SS` countdown for the status item, updated at 1 Hz.
    private(set) var countdownText: String = ""
    /// Last failure worth showing in the menu; cleared on the next success.
    private(set) var lastError: String?

    var isActive: Bool { session != nil && pendingEnds == 0 }
    /// Confirmed by a successful sleep-guard command, independent of journal intent.
    private(set) var sleepHeld = false
    /// Includes unreadable journals and failed durable cleanup, not just known owned fields.
    private(set) var cleanupPending = false
    private(set) var backstopArmed = false
    @ObservationIgnored private let operationGate = SessionOperationGate()
    @ObservationIgnored private var generation: UInt64 = 0
    private var pendingEnds = 0

    /// Fire date of the single deadline timer, exposed for tests and the menu.
    private(set) var scheduledDeadline: Date?

    let store: Store
    let paths: Paths
    private let sleepGuard: any SleepGuarding
    private let processControl: any ProcessSignaling
    private let backstop: any BackstopScheduling
    private let audio: any AudioControlling
    private let notifier: any Notifying
    private let clamshell: @Sendable () -> Bool?
    private let clock: @Sendable () -> Date
    private let installerGuardActive: @Sendable () -> Bool

    /// System integrations (lid, battery, network, ...). Set by `live()`;
    /// nil in tests. Started after a session starts, stopped when it ends.
    @ObservationIgnored var services: AppServices?

    @ObservationIgnored private var cleanupTimer: Timer?
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var countdownTimer: Timer?
    /// Whether the 1 Hz redraw is currently on the run loop. Tests assert on
    /// this to prove an idle session leaves no repeating wakeup behind.
    var countdownTimerArmed: Bool { countdownTimer != nil }
    var cleanupRetryScheduled: Bool { cleanupTimer != nil }
    @ObservationIgnored private var countdownPaused = false

    init(
        paths: Paths,
        sleepGuard: any SleepGuarding,
        processControl: any ProcessSignaling,
        backstop: any BackstopScheduling,
        audio: any AudioControlling = NoopAudioControl(),
        notifier: any Notifying = RecordingNotifier(),
        clamshell: @escaping @Sendable () -> Bool? = { LidObserver.readClamshellState() },
        clock: @escaping @Sendable () -> Date = { Date() },
        installerGuardActive: @escaping @Sendable () -> Bool = { AppInstanceLease.isInstallationActive() }
    ) {
        self.paths = paths
        self.store = Store(paths: paths)
        self.sleepGuard = sleepGuard
        self.processControl = processControl
        self.backstop = backstop
        self.audio = audio
        self.notifier = notifier
        self.clamshell = clamshell
        self.clock = clock
        self.installerGuardActive = installerGuardActive

        try? paths.createDirectories()
        self.state = .clean
        do { self.state = try store.loadState() ?? .clean }
        catch {
            cleanupPending = true
            lastError = "Recovery state is unreadable: \(error.localizedDescription)"
        }
        initialSession = (try? store.loadSession()) ?? nil
        if let c = (try? store.loadConfig()) ?? nil {
            self.config = c
        } else {
            self.config = Config()
            try? store.saveConfig(self.config)
        }
    }

    /// Production wiring.
    static func live(paths: Paths = .fromEnvironment()) -> SessionManager {
        let notifier = Notifier()
        let audio = CoreAudioControl()
        let processControl = SignalProcessControl()
        let m = SessionManager(
            paths: paths,
            sleepGuard: PmsetSleepGuard(),
            processControl: processControl,
            backstop: LaunchdBackstop(paths: paths),
            audio: audio,
            notifier: notifier
        )
        let services = AppServices(paths: paths, notifier: notifier, audio: audio, processControl: processControl)
        m.services = services
        services.logStartupSnapshot()
        return m
    }

    // MARK: Start / extend / end

    /// Start a session of `duration` seconds (clamped to `config.maxDuration`).
    /// Ignored if a session is already active; use `extend`.
    ///
    /// Ordering: session.json, then state.json, then `pmset disablesleep 1`.
    /// If pmset fails, compensate before clearing its recovery ownership.
    func start(duration: TimeInterval) async {
        let requestedGeneration = generation
        guard pendingEnds == 0 else { return }
        await operationGate.acquire()
        defer { operationGate.release() }
        guard requestedGeneration == generation, !Task.isCancelled else { return }
        await withRecoveryLease {
            guard requestedGeneration == generation, !Task.isCancelled,
                  activationIsAllowed() else { return }
            await startUnlocked(duration: duration)
        }
    }

    private func startUnlocked(duration: TimeInterval) async {
        do {
            if let recorded = try store.loadSession(), !recorded.isExpired(at: clock()) {
                if session != nil, try validateOwnership() {
                    Log.info("start ignored: session already active")
                    return
                }
                fail("could not start: a session already exists on disk")
                return
            }
            if session != nil { invalidateLocalSession() }
            state = try store.loadState() ?? .clean
        } catch {
            cleanupFailed("could not read journal before start: \(error.localizedDescription)")
            return
        }
        // A previous failed cleanup still owns those changes. Restore before
        // writing a new session, and require the clean journal to reach disk.
        do {
            let recorded = try store.loadState()
            if cleanupPending || state.isDirty || recorded?.isDirty == true {
                cleanupPending = false
                await restoreAllUnlocked()
                let remaining = try store.loadState() ?? state
                guard !cleanupPending, !state.isDirty, !remaining.isDirty else {
                    fail("could not start: previous session cleanup is incomplete")
                    return
                }
            }
        } catch {
            cleanupFailed("could not read recovery state before start: \(error.localizedDescription)")
            return
        }
        guard pendingEnds == 0, !Task.isCancelled else { return }
        let now = clock()
        let new = SessionMath.newSession(now: now, duration: duration, maxDuration: config.maxDuration)
        let original: Bool
        do { original = try await sleepGuard.isSleepDisabled() }
        catch { fail("could not read original sleep setting: \(error.localizedDescription)"); return }
        guard pendingEnds == 0, !Task.isCancelled else { return }

        do {
            try store.saveSession(new)
            var s = state
            s.sleepDisabledByUs = !original
            s.originalSleepDisabled = original ? nil : original
            try persistState(s)
        } catch {
            fail("could not write session: \(error.localizedDescription)")
            try? store.deleteSession()
            return
        }

        // The backstop is armed before sleep is disabled, so a crash at any
        // later point already has a launchd job waiting at the deadline.
        // RunAtLoad fires backstop.sh immediately; the session on disk is
        // valid, so that run is a no-op.
        do {
            try await scheduleBackstop(endsAt: new.endsAt)
        } catch {
            rollBackStart()
            fail("could not arm backstop: \(error.localizedDescription)")
            return
        }

        do {
            if !original { try await sleepGuard.setSleepDisabled(true) }
        } catch {
            // A failed command can have partially applied; keep ownership until
            // a compensating restore succeeds.
            await endUnlocked(reason: .backstop)
            fail("could not disable sleep: \(error.localizedDescription)")
            return
        }

        session = new
        initialSession = nil
        sleepHeld = true
        countdownPaused = clamshell() == true
        lastError = nil
        Log.info("session started until \(iso(new.endsAt)) (\(Int(duration))s requested)")
        await armDeadline(new.endsAt)
        // App Nap defaults and every observer live in AppServices.
        if pendingEnds == 0 { services?.start(for: self) }
        // PR3: schedule "5 minutes left" notification.
    }

    func extend(by extra: TimeInterval) async {
        let requestedGeneration = generation
        guard pendingEnds == 0 else { return }
        await operationGate.acquire()
        defer { operationGate.release() }
        guard requestedGeneration == generation, !Task.isCancelled else { return }
        await withRecoveryLease {
            guard requestedGeneration == generation, !Task.isCancelled else { return }
            try await extendUnlocked(by: extra)
        }
    }

    private func extendUnlocked(by extra: TimeInterval) async throws {
        guard try validateOwnership(requireActive: true),
              let current = session else { return }
        let updated = SessionMath.extended(current, by: extra, now: clock(), maxDuration: config.maxDuration)
        // A failed replacement may also have lost its previous recovery job.
        do {
            try await scheduleBackstop(endsAt: updated.endsAt)
        } catch {
            await endUnlocked(reason: .backstop)
            fail("could not move backstop: \(error.localizedDescription)")
            return
        }
        do {
            try store.saveSession(updated)
        } catch {
            // Disk and recovery disagree; safely end instead of accepting either deadline.
            await endUnlocked(reason: .backstop)
            fail("could not write session: \(error.localizedDescription)")
            return
        }
        session = updated
        lastError = nil
        Log.info("session extended by \(Int(extra))s until \(iso(updated.endsAt))")
        await armDeadline(updated.endsAt)
    }

    /// Full session end: delete the session file first (so a crash here leaves
    /// a clean "no session" for reconcile/backstop), then undo RuntimeState
    /// from disk, then clear the backstop trigger.
    func end(reason: EndReason) async {
        generation &+= 1
        pendingEnds += 1
        // Stop producers now; already-started mutations finish before cleanup.
        services?.stop()
        await operationGate.acquire()
        defer {
            pendingEnds -= 1
            operationGate.release()
        }
        await withRecoveryLease {
            guard try validateOwnership() else { return }
            await endUnlocked(reason: reason)
        }
    }

    private func endUnlocked(reason: EndReason) async {
        // Recovery-triggered ends also invalidate work already queued at the gate.
        generation &+= 1
        let had = session != nil
        cleanupPending = false
        Log.info("session end (\(reason.rawValue))")
        stopTimers()
        session = nil
        initialSession = nil
        scheduledDeadline = nil
        remainingText = ""
        countdownText = ""
        countdownPaused = false
        do {
            try store.deleteSession()
        } catch {
            cleanupFailed("could not delete session.json: \(error.localizedDescription)")
        }
        services?.stop()
        await restoreAllUnlocked()
        // Keep independent recovery armed when any restoration still needs retry.
        if !cleanupPending, !state.isDirty {
            do {
                backstopArmed = false
                try await backstop.clear()
            } catch {
                cleanupFailed("backstop clear failed: \(error.localizedDescription)")
            }
        }
        if cleanupPending || state.isDirty {
            cleanupPending = true
            await armCleanupRecovery()
            if lastError == nil { fail("session cleanup is incomplete") }
            notifier.post(title: "Cleanup incomplete", body: "Some session changes could not be restored. Recovery information was kept; retry cleanup before starting another session.")
        } else {
            lastError = nil
            notifier.post(title: Self.endTitle(reason, had: had), body: endBody(reason))
        }
    }

    // MARK: Journal hooks for LidActions / FloorRules

    /// Persist a state mutation (journal first) and keep the in-memory copy
    /// in sync. Throws if state.json cannot be written; callers must then
    /// skip the side effect.
    func journal(_ mutate: (inout RuntimeState) -> Void) throws {
        try JournalLock.withLock(at: paths.recoveryLock) {
            var s = try store.loadState() ?? .clean
            mutate(&s)
            try persistState(s)
        }
    }

    /// Short, non-suspending lid transaction: validity, journal, and effect are
    /// all protected. Contention skips this close action instead of blocking UI.
    func withLidTransaction(_ operation: () throws -> Void) throws {
        try JournalLock.withLock(at: paths.recoveryLock) {
            guard isActive, try validateOwnership(requireActive: true) else { return }
            try operation()
        }
    }

    /// Low Power Mode with journaling: the flag is written before `pmset -b
    /// lowpowermode 1` and cleared only after `... 0` succeeds. Returns true
    /// when the mode was actually changed.
    @discardableResult
    func setLowPower(_ on: Bool) async -> Bool {
        let requestedGeneration = generation
        let requestedSession = session?.startedAt
        await operationGate.acquire()
        defer { operationGate.release() }
        guard requestedGeneration == generation, !Task.isCancelled,
              !on || (isActive && session?.startedAt == requestedSession) else { return false }
        var changed = false
        await withRecoveryLease {
            guard requestedGeneration == generation, !Task.isCancelled,
                  try validateOwnership(requireActive: on),
                  !on || isActive else { return }
            state = try store.loadState() ?? .clean
            changed = await setLowPowerUnlocked(on)
        }
        return changed && requestedGeneration == generation && pendingEnds == 0
    }

    private func setLowPowerUnlocked(_ on: Bool) async -> Bool {
        if on {
            guard !state.lowPowerSetByUs, state.originalBatteryLowPowerMode == nil else { return false }
            do {
                let original = try await sleepGuard.batteryLowPowerMode()
                guard !original, isActive, !Task.isCancelled else { return false }
                try journal {
                    $0.originalBatteryLowPowerMode = original
                    $0.lowPowerSetByUs = true
                }
            } catch {
                fail("could not snapshot/journal low power mode: \(error.localizedDescription)")
                return false
            }
            do {
                try await sleepGuard.setLowPowerMode(true)
                Log.info("low power mode on")
                return true
            } catch {
                fail("could not enable low power mode: \(error.localizedDescription)")
                _ = await setLowPowerUnlocked(false)
                return false
            }
        } else {
            guard state.lowPowerSetByUs || state.originalBatteryLowPowerMode != nil else { return false }
            do {
                try await sleepGuard.setLowPowerMode(state.originalBatteryLowPowerMode ?? false)
                try journal {
                    $0.lowPowerSetByUs = false
                    $0.originalBatteryLowPowerMode = nil
                }
                Log.info("original battery low power mode restored")
                return true
            } catch {
                cleanupFailed("could not restore low power mode: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Undo every lid-close action recorded on disk: resume frozen pids,
    /// clear the Docker marker, restore volume and mute. Used by lid open,
    /// reconcile (lid open) and the full restore.
    func undoLidActions() async {
        let requestedGeneration = generation
        await operationGate.acquire()
        defer { operationGate.release() }
        guard requestedGeneration == generation else { return }
        await withRecoveryLease {
            guard requestedGeneration == generation, try validateOwnership() else { return }
            undoLidActionsUnlocked()
        }
    }

    private func undoLidActionsUnlocked() {
        do {
            var s = try store.loadState() ?? state
            state = s
            undoLidActions(in: &s)
        } catch {
            cleanupFailed("state.json unreadable; recovery information retained: \(error.localizedDescription)")
        }
    }

    // MARK: Restore

    /// Undo every RuntimeState entry, reading state.json from disk. Each undo
    /// is persisted as soon as it succeeds so a crash mid-way loses nothing.
    /// Failures are logged and the entry is left set so the next reconcile or
    /// the backstop retries it.
    func restoreAll() async {
        await operationGate.acquire()
        defer { operationGate.release() }
        await withRecoveryLease {
            guard try validateOwnership() else { return }
            await restoreAllUnlocked()
        }
    }

    private func restoreAllUnlocked() async {
        var s: RuntimeState
        do { s = try store.loadState() ?? state }
        catch {
            cleanupFailed("state.json unreadable; recovery information retained: \(error.localizedDescription)")
            return
        }
        state = s
        if s.sleepDisabledByUs || s.originalSleepDisabled != nil {
            do {
                let original = s.originalSleepDisabled ?? false
                try await sleepGuard.setSleepDisabled(original)
                sleepHeld = original
                s.sleepDisabledByUs = false
                s.originalSleepDisabled = nil
                try persistState(s)
                Log.info("original sleep setting restored")
            } catch { cleanupFailed("could not restore sleep: \(error.localizedDescription)") }
        }
        if s.lowPowerSetByUs || s.originalBatteryLowPowerMode != nil {
            do {
                try await sleepGuard.setLowPowerMode(s.originalBatteryLowPowerMode ?? false)
                s.lowPowerSetByUs = false
                s.originalBatteryLowPowerMode = nil
                try persistState(s)
                Log.info("original battery low power mode restored")
            } catch { cleanupFailed("could not restore low power mode: \(error.localizedDescription)") }
        }
        undoLidActions(in: &s)
    }

    /// Shared body of `undoLidActions()` and `restoreAll()`; each entry is
    /// persisted as soon as it is undone.
    private func undoLidActions(in s: inout RuntimeState) {
        if !s.frozenPids.isEmpty {
            processControl.resume(pids: s.frozenPids)
            Log.info("resumed \(s.frozenPids.count) frozen pid(s)")
            s.frozenPids = []
            // Docker Desktop is frozen via its pids too; the flag is only a marker.
            s.dockerFrozen = false
            try? persistState(s)
        } else if s.dockerFrozen {
            s.dockerFrozen = false
            try? persistState(s)
        }

        if s.savedOutputVolume != nil || s.savedMuted != nil {
            do {
                let current = try audio.read()
                try audio.apply(volume: s.savedOutputVolume ?? current.volume, muted: s.savedMuted ?? current.muted)
                Log.info("audio restored (volume \(s.savedOutputVolume ?? current.volume), muted \(s.savedMuted ?? current.muted))")
                s.savedOutputVolume = nil
                s.savedMuted = nil
                try? persistState(s)
            } catch {
                Log.error("could not restore audio: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Reconcile (spec section 8)

    func reconcile() async {
        let requestedGeneration = generation
        guard pendingEnds == 0 else { return }
        await operationGate.acquire()
        defer { operationGate.release() }
        guard requestedGeneration == generation, !Task.isCancelled else { return }
        await withRecoveryLease {
            guard requestedGeneration == generation, !Task.isCancelled,
                  activationIsAllowed() else { return }
            await reconcileUnlocked()
        }
    }

    private func reconcileUnlocked() async {
        let now = clock()
        // Another process may have recovered since this manager was created.
        do { state = try store.loadState() ?? state }
        catch {
            await endUnlocked(reason: .backstop)
            cleanupFailed("could not read recovery state: \(error.localizedDescription)")
            return
        }
        do {
            if session != nil, try !validateOwnership() { return }
        } catch {
            cleanupFailed("could not read session identity: \(error.localizedDescription)")
            return
        }
        var onDisk: Session?
        do {
            onDisk = try store.loadSession()
        } catch {
            Log.error("session.json unreadable (\(error.localizedDescription)); treating as expired")
            onDisk = nil
        }

        if let s = onDisk, !s.isExpired(at: now) {
            let original: Bool
            do {
                original = try await sleepGuard.isSleepDisabled()
                if !state.sleepDisabledByUs, state.originalSleepDisabled == nil, !original {
                    var st = state
                    st.sleepDisabledByUs = true
                    st.originalSleepDisabled = original
                    try persistState(st)
                }
            } catch {
                await endUnlocked(reason: .backstop)
                fail("could not snapshot/journal reconciled session: \(error.localizedDescription)")
                return
            }
            do {
                try await scheduleBackstop(endsAt: s.endsAt)
            } catch {
                await endUnlocked(reason: .backstop)
                fail("could not re-arm backstop: \(error.localizedDescription)")
                return
            }
            do {
                if !original || state.sleepDisabledByUs || state.originalSleepDisabled != nil {
                    try await sleepGuard.setSleepDisabled(true)
                }
            } catch {
                await endUnlocked(reason: .backstop)
                fail("could not re-apply sleep guard: \(error.localizedDescription)")
                return
            }
            sleepHeld = true
            session = s
            initialSession = nil
            lastError = nil
            Log.info("reconcile: session valid until \(iso(s.endsAt))")
            let lidClosed = clamshell()
            countdownPaused = lidClosed == true
            if lidClosed == false {
                undoLidActionsUnlocked()
            } else if !state.frozenPids.isEmpty || state.savedOutputVolume != nil {
                Log.info("reconcile: lid \(lidClosed == nil ? "unknown" : "closed"), keeping lid-close actions")
            }
            await armDeadline(s.endsAt)
            if pendingEnds == 0 { services?.start(for: self) }
            return
        }

        // Step 1: missing or expired -> full end.
        if onDisk != nil {
            Log.info("reconcile: session expired, restoring")
            await endUnlocked(reason: .timer)
        } else if cleanupPending || state.isDirty {
            Log.info("reconcile: no session but dirty state, restoring")
            await endUnlocked(reason: .backstop)
        } else {
            Log.info("reconcile: no session, nothing to restore")
        }

        // With no owned journal, an existing sleep preference belongs to the user.
    }

    /// A failed cleanup must not be bypassed by a second quit request.
    func prepareToQuit() async -> Bool {
        await end(reason: .quit)
        guard !cleanupPending, !state.isDirty, session == nil, pendingEnds == 0 else {
            cleanupFailed("Quit cancelled: session cleanup is incomplete. Fix the reported recovery error and retry Quit.")
            return false
        }
        return true
    }

    // MARK: Countdown (1 Hz redraw)

    /// Stop the countdown redraw. The lid observer calls this on lid close,
    /// which is what keeps a 1 Hz timer from costing battery in the bag.
    func pauseCountdown() {
        countdownPaused = true
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Restart the countdown redraw. The lid observer calls this on lid open.
    func resumeCountdown() {
        countdownPaused = false
        refreshCountdown()
        armCountdownTimer()
    }

    /// Recompute `remainingText` and `countdownText` from the injected clock.
    /// Each is only assigned when it changes, so observers are not woken every
    /// second for the minute-granularity text.
    func refreshCountdown() {
        guard let s = session else {
            remainingText = ""
            countdownText = ""
            return
        }
        let remaining = s.remaining(at: clock())
        let minute = SessionMath.formatRemaining(remaining)
        if remainingText != minute { remainingText = minute }
        let second = SessionMath.formatCountdown(remaining: remaining, shape: s.countdownShape)
        if countdownText != second { countdownText = second }
    }

    // MARK: Private

    private func activationIsAllowed() -> Bool {
        guard !installerGuardActive() else {
            fail("could not activate session: Insomnia installation or removal is in progress")
            return false
        }
        return true
    }

    private func withRecoveryLease(_ operation: () async throws -> Void) async {
        do {
            try await JournalLock.withLease(at: paths.recoveryLock, operation)
        } catch {
            cleanupPending = true
            fail("could not coordinate recovery: \(error.localizedDescription)")
        }
    }

    /// Compare serialized identity because ISO8601 persistence drops fractional
    /// seconds. A stale manager must never delete or resurrect another journal.
    private func validateOwnership(requireActive: Bool = false) throws -> Bool {
        let recorded = try store.loadSession()
        if let expected = session ?? initialSession {
            guard let recorded,
                  try Store.makeEncoder().encode(expected) == Store.makeEncoder().encode(recorded) else {
                invalidateLocalSession()
                state = try store.loadState() ?? .clean
                return false
            }
            if requireActive, session == nil { return false }
        } else if requireActive || (recorded.map { !$0.isExpired(at: clock()) } ?? false) {
            return false
        }
        // Recovery itself handles unreadable state conservatively; mutations
        // require a successful fresh read before writing any ownership.
        if requireActive { state = try store.loadState() ?? .clean }
        return true
    }

    private func invalidateLocalSession() {
        generation &+= 1
        services?.stop()
        stopTimers()
        session = nil
        initialSession = nil
        sleepHeld = false
        scheduledDeadline = nil
        remainingText = ""
        countdownText = ""
        countdownPaused = false
    }

    /// Undo the journal written at the top of `start`.
    private func rollBackStart() {
        var s = state
        s.sleepDisabledByUs = false
        s.originalSleepDisabled = nil
        do { try persistState(s); try store.deleteSession() }
        catch { cleanupFailed("could not roll back start: \(error.localizedDescription)") }
    }

    /// In-process timers only; the launchd backstop is scheduled by callers
    /// before this runs.
    private func armDeadline(_ endsAt: Date) async {
        deadlineTimer?.invalidate()
        scheduledDeadline = endsAt
        // One timer at the deadline. Fire dates in the past fire immediately.
        let timer = Timer(fire: endsAt, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.session, s.isExpired(at: self.clock()) else { return }
                await self.end(reason: .timer)
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer

        refreshCountdown()
        if !countdownPaused { armCountdownTimer() }
    }

    /// 1 Hz redraw aligned to whole wall-clock seconds so the digits change
    /// in step with the menu bar clock. `pauseCountdown()` stops it entirely
    /// while the lid is closed.
    private func armCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        // Nothing to redraw without a session. Guarding here rather than in
        // `resumeCountdown` covers every caller: a session that ends while the
        // lid is shut would otherwise leave lid-open arming a 1 Hz timer that
        // wakes the run loop forever to format an empty string.
        guard session != nil else { return }
        let first = SessionMath.nextSecondBoundary(after: clock())
        let timer = Timer(fire: first, interval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCountdown() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func stopTimers() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func persistState(_ s: RuntimeState) throws {
        do { try store.saveState(s); state = s }
        catch { cleanupPending = true; throw error }
    }

    private func scheduleBackstop(endsAt: Date) async throws {
        backstopArmed = false
        try await backstop.schedule(endsAt: endsAt)
        backstopArmed = true
    }

    private func cleanupFailed(_ message: String) {
        cleanupPending = true
        fail(message)
    }

    /// Retry arming even if a failed replacement already removed the old job.
    /// Keep a local retry too, and refuse quit until cleanup itself succeeds.
    private func armCleanupRecovery() async {
        do { try await scheduleBackstop(endsAt: clock()) }
        catch { cleanupFailed("could not arm cleanup recovery: \(error.localizedDescription)") }
        cleanupTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.end(reason: .backstop) }
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    private func fail(_ message: String) {
        lastError = message
        Log.error(message)
    }

    private func iso(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    private static func endTitle(_ reason: EndReason, had: Bool) -> String {
        switch reason {
        case .backstop: "Sleep restored"
        default: had ? "Session ended" : "Session restored"
        }
    }

    private func endBody(_ reason: EndReason) -> String {
        switch reason {
        case .timer: "Time is up. Sleep is back to normal."
        case .user: "Ended by you. Sleep is back to normal."
        case .quit: "Insomnia quit. Sleep is back to normal."
        case .batteryFloor: "Battery fell below \(config.endFloor)%. Sleep is back to normal."
        case .thermalCritical: "Thermal state is critical. Sleep is back to normal."
        case .backstop: "A previous session left changes behind; everything has been undone."
        }
    }
}
