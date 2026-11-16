// DrivingModeController.swift
// Driving mode for the Mac app: a mode entered once and then run for hours
// from the headset's buttons, with the laptop used only to replay a recent
// reply. See notes/mac-driving-mode.md.
//
// The controller, not a view, owns everything the mode needs for the length of
// a drive, and re-asserts it on a timer so nothing that drifts stays drifted:
//
//   • the session being driven stays the active one and stays subscribed, so
//     replies keep arriving and keep being read aloud, with no conversation
//     view on screen to do it;
//   • the Mac is kept awake and the app out of App Nap;
//   • a lost connection is retried for as long as the mode is on, and said
//     aloud, because the driver cannot see a red dot;
//   • the headset button source and the audible cues are on, and speech is
//     not muted;
//   • a reply that arrived while the microphone was open (and was therefore
//     not read) is read when the microphone closes.
//
// Sending needs no wiring here: with no conversation view injected,
// HeadsetRemoteCommandManager sends to the active session itself.

#if os(macOS)
import Foundation
import Combine
import CoreData

private func dLog(_ message: String) {
    LogManager.shared.log(message, category: "DrivingMode")
}

/// Keeps the Mac awake and the app un-napped for the length of a drive.
protocol DrivingPowerAssertion: AnyObject {
    var isHeld: Bool { get }
    func begin(reason: String)
    func end()
}

final class SystemDrivingPowerAssertion: DrivingPowerAssertion {
    private var token: NSObjectProtocol?

    var isHeld: Bool { token != nil }

    func begin(reason: String) {
        guard token == nil else { return }
        // userInitiated: no App Nap, no timer throttling, no idle system sleep.
        // idleDisplaySleepDisabled: the replay tiles stay visible and clickable.
        // The termination options stop macOS quitting an app it thinks is idle.
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled,
                      .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: reason)
    }

    func end() {
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
    }
}

final class DrivingModeController: ObservableObject {
    /// Whether driving mode is on. The root view shows the driving screen
    /// instead of the sidebar and conversation while this is true.
    @Published private(set) var isActive = false
    /// The session being driven. Nil when there was no session to pick.
    @Published private(set) var sessionId: UUID?
    @Published private(set) var sessionName = ""
    /// The replies offered for replay, newest first, at most `replayCount`.
    @Published private(set) var replies: [RecentReply] = []
    /// Bumped on every health check. The window pinner re-checks the window on it.
    @Published private(set) var healthTick = 0
    /// The reply most recently replayed, so its tile can flash.
    @Published private(set) var lastReplayedId: UUID?

    /// Seconds between health checks.
    static let healthInterval: TimeInterval = 10
    /// How long the connection may be down before it is announced and forced.
    static let reconnectGrace: TimeInterval = 15
    /// Seconds between forced reconnects during an outage. The client's own
    /// backoff gives up after a fixed number of attempts; driving mode never does.
    static let forcedReconnectInterval: TimeInterval = 30
    /// Rows looked at when checking for replies that arrived while the
    /// microphone was open. More than the tiles show, so a burst is not missed.
    static let replyScanLimit = 8

    private let settings: AppSettings
    private let client: VoiceCodeClient
    private let voiceOutput: VoiceOutputManager
    private let voiceInput: VoiceInputManager
    private let headset: HeadsetRemoteCommandManager
    private let activeSession: ActiveSessionManager
    private let viewContext: () -> NSManagedObjectContext
    private let power: DrivingPowerAssertion
    private let now: () -> Date

    /// Starts the repeating health check and returns its handle. Test seam:
    /// tests replace it with a no-op and call `healthCheck()` themselves.
    var startHealthTimer: (@escaping () -> Void) -> AnyCancellable = { tick in
        Timer.publish(every: DrivingModeController.healthInterval, on: .main, in: .common)
            .autoconnect()
            .sink { _ in tick() }
    }

    private var healthTimer: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    /// The settings as they were before the mode changed them, restored on exit.
    private struct SavedSettings {
        let headsetModeEnabled: Bool
        let blueParrottEnabled: Bool
        let audibleCuesEnabled: Bool
        let muted: Bool
    }
    private var savedSettings: SavedSettings?

    private var sessionWorkingDirectory: String?
    private var disconnectedSince: Date?
    private var lastForcedReconnect: Date?
    private var announcedConnectionLost = false
    private var stuckGateChecks = 0

    /// Every reply seen so far this drive, so a new one can be told from an old one.
    private var knownReplyIds = Set<UUID>()
    /// False until the replies already there at entry have been recorded as
    /// known. Those are history, not arrivals.
    private var repliesSeeded = false
    /// Replies that arrived while the microphone was open, oldest first. Speech
    /// is dropped while recording, so these were never read.
    private var heldReplies: [RecentReply] = []

    init(settings: AppSettings,
         client: VoiceCodeClient,
         voiceOutput: VoiceOutputManager,
         voiceInput: VoiceInputManager,
         headset: HeadsetRemoteCommandManager,
         activeSession: ActiveSessionManager = .shared,
         viewContext: @escaping () -> NSManagedObjectContext = { PersistenceController.shared.container.viewContext },
         power: DrivingPowerAssertion = SystemDrivingPowerAssertion(),
         now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.client = client
        self.voiceOutput = voiceOutput
        self.voiceInput = voiceInput
        self.headset = headset
        self.activeSession = activeSession
        self.viewContext = viewContext
        self.power = power
        self.now = now

        // Something else cleared or changed the active session (a conversation
        // view disappearing does both): take it back on the next main-queue turn,
        // after that view's teardown has also unsubscribed.
        activeSession.$activeSessionId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self, self.isActive, let id = self.sessionId, active != id else { return }
                dLog("active session drifted to \(active?.uuidString.lowercased() ?? "nil"), re-asserting \(id.uuidString.lowercased())")
                self.assertWiring()
            }
            .store(in: &cancellables)

        client.$isConnected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in self?.connectionChanged(connected) }
            .store(in: &cancellables)

        // A fresh socket has no subscriptions until the client is authenticated.
        client.$isAuthenticated
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] authenticated in
                guard authenticated else { return }
                self?.assertWiring()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .sessionHistoryDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, self.isActive, let id = self.sessionId,
                      (note.userInfo?["sessionId"] as? String)?.lowercased() == id.uuidString.lowercased() else { return }
                self.refreshReplies()
            }
            .store(in: &cancellables)

        // The microphone closed: read what arrived while it was open.
        voiceInput.$isRecording
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording in
                guard !recording else { return }
                self?.flushHeldReplies()
            }
            .store(in: &cancellables)

        settings.$drivingReplayCount
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshReplies() }
            .store(in: &cancellables)
    }

    deinit {
        power.end()
    }

    // MARK: - Entering and leaving

    /// Turn driving mode on for `preferred`, or, when that is nil or unknown,
    /// for the session already active, the one driven last time, or the most
    /// recently used one. Safe to call again while on: it re-targets the session.
    func enter(preferred: UUID? = nil) {
        let context = viewContext()
        let session = Self.resolveSession(preferred: preferred,
                                          active: activeSession.activeSessionId,
                                          persisted: settings.drivingSessionId,
                                          in: context)
        let wasActive = isActive
        let previousSession = sessionId
        sessionId = session?.id
        sessionWorkingDirectory = session?.workingDirectory
        sessionName = session.map { Self.readableName(for: $0, in: context) } ?? ""

        if !wasActive {
            applyDrivingSettings()
            power.begin(reason: "Untethered driving mode")
            healthTimer = startHealthTimer { [weak self] in self?.healthCheck() }
            disconnectedSince = client.isConnected ? nil : now()
            lastForcedReconnect = nil
            announcedConnectionLost = false
            stuckGateChecks = 0
        }
        if !wasActive || previousSession != sessionId {
            knownReplyIds.removeAll()
            heldReplies.removeAll()
            repliesSeeded = false
        }

        settings.drivingSessionId = sessionId
        settings.drivingModeEnabled = true
        isActive = true

        dLog("entered: session=\(sessionId?.uuidString.lowercased() ?? "none") name='\(sessionName)' connected=\(client.isConnected) headsetControl=\(settings.headsetModeEnabled) blueParrott=\(settings.blueParrottEnabled) replayCount=\(settings.drivingReplayCount)")

        refreshReplies()
        assertWiring()
        // A conversation view on screen at entry is torn down after this returns,
        // and its teardown clears the active session and unsubscribes. Assert
        // again once that has happened.
        DispatchQueue.main.async { [weak self] in self?.assertWiring() }

        if !wasActive {
            announce(entryAnnouncement())
        }
    }

    /// Turn driving mode off and put back the settings it changed. The session
    /// stays active and subscribed: the conversation view that reappears takes
    /// over from there.
    func exit() {
        guard isActive else { return }
        healthTimer?.cancel()
        healthTimer = nil
        power.end()
        restoreSettings()
        settings.drivingModeEnabled = false
        isActive = false
        heldReplies.removeAll()
        dLog("exited")
    }

    func toggle(preferred: UUID? = nil) {
        if isActive { exit() } else { enter(preferred: preferred) }
    }

    // MARK: - Replay

    /// Read the reply on tile `index` (0 is the newest) again, from the top.
    func replay(index: Int) {
        guard replies.indices.contains(index) else {
            dLog("replay \(index + 1) ignored: only \(replies.count) replies")
            return
        }
        replay(replies[index])
    }

    /// Read `reply` again now. Whatever is being read is cut off; replies that
    /// have not been read yet are kept and follow it.
    func replay(_ reply: RecentReply) {
        lastReplayedId = reply.id
        let started = voiceOutput.replay(reply.spokenText,
                                         workingDirectory: sessionWorkingDirectory,
                                         sessionId: sessionId)
        dLog("replay \(reply.id.uuidString.lowercased()) length=\(reply.spokenText.count) started=\(started) recording=\(voiceOutput.isRecordingActive)")
    }

    // MARK: - Health

    /// Put back anything that has drifted. Runs every `healthInterval` while
    /// the mode is on. Every step is idempotent.
    func healthCheck() {
        guard isActive else { return }
        healthTick &+= 1
        if !power.isHeld {
            dLog("power assertion was not held, taking it again")
            power.begin(reason: "Untethered driving mode")
        }
        if voiceOutput.isMuted {
            dLog("speech was muted, unmuting")
            voiceOutput.isMuted = false
        }
        assertWiring()
        refreshReplies()
        checkConnection()
        healStuckRecordingGate()
    }

    /// Keep the driven session active and subscribed.
    func assertWiring() {
        guard isActive, let id = sessionId else { return }
        if activeSession.activeSessionId != id {
            activeSession.setActiveSession(id)
        }
        // A session created here that has never been sent to has no file on the
        // backend to subscribe to. The first prompt creates it and the client
        // subscribes when the backend reports it ready.
        let request = CDBackendSession.fetchBackendSession(id: id)
        if let session = try? viewContext().fetch(request).first,
           session.isLocallyCreated, session.messageCount == 0 {
            return
        }
        client.subscribe(sessionId: id.uuidString.lowercased())
    }

    /// Reload the replay tiles and note replies that arrived with the microphone open.
    func refreshReplies() {
        guard isActive, let id = sessionId else {
            if !replies.isEmpty { replies = [] }
            return
        }
        let count = DrivingModeLayout.clampedReplayCount(settings.drivingReplayCount)
        let scanned = RecentReplies.fetch(sessionId: id,
                                          limit: max(count, Self.replyScanLimit),
                                          in: viewContext())
        let fresh = scanned.filter { !knownReplyIds.contains($0.id) }
        if repliesSeeded, !fresh.isEmpty, voiceOutput.isRecordingActive {
            // Newest first in `scanned`; hold them oldest first, the order to read them in.
            heldReplies.append(contentsOf: fresh.reversed())
            dLog("\(fresh.count) reply(ies) arrived with the microphone open, held to read after it closes (\(heldReplies.count) held)")
        }
        if knownReplyIds.count > 500 { knownReplyIds.removeAll() }
        knownReplyIds.formUnion(scanned.map(\.id))
        repliesSeeded = true

        let shown = Array(scanned.prefix(count))
        if shown != replies { replies = shown }
    }

    private func flushHeldReplies() {
        guard isActive, !heldReplies.isEmpty else { return }
        guard !voiceOutput.isRecordingActive else { return }   // still open; the next close flushes
        let held = heldReplies
        heldReplies.removeAll()
        dLog("microphone closed, reading \(held.count) held reply(ies)")
        for reply in held {
            voiceOutput.enqueue(reply.spokenText, workingDirectory: sessionWorkingDirectory, sessionId: sessionId)
        }
    }

    private func connectionChanged(_ connected: Bool) {
        guard isActive else { return }
        if connected {
            disconnectedSince = nil
            lastForcedReconnect = nil
            if announcedConnectionLost {
                announcedConnectionLost = false
                announce("Reconnected.")
            }
            assertWiring()
        } else if disconnectedSince == nil {
            disconnectedSince = now()
            dLog("connection lost")
        }
    }

    private func checkConnection() {
        guard !client.isConnected else {
            disconnectedSince = nil
            return
        }
        let since = disconnectedSince ?? now()
        disconnectedSince = since
        guard now().timeIntervalSince(since) >= Self.reconnectGrace else { return }

        // Two states a retry cannot fix. Say so once and stop hammering.
        if client.requiresUpgrade || client.requiresReauthentication {
            if !announcedConnectionLost {
                announcedConnectionLost = true
                announce(client.requiresUpgrade
                         ? "The server needs a newer version of this app. Driving mode cannot reconnect."
                         : "The server rejected this app's key. Driving mode cannot reconnect.")
            }
            return
        }
        if !announcedConnectionLost {
            announcedConnectionLost = true
            announce("Connection lost. Retrying.")
        }
        if let last = lastForcedReconnect, now().timeIntervalSince(last) < Self.forcedReconnectInterval {
            return
        }
        lastForcedReconnect = now()
        dLog("still disconnected after \(Int(now().timeIntervalSince(since)))s, forcing a reconnect")
        client.forceReconnect()
    }

    /// The recording gate drops all speech while it is up. If it is up with no
    /// recording in progress, two checks running, it is stuck: lower it, or
    /// every reply for the rest of the drive is silently dropped.
    private func healStuckRecordingGate() {
        guard voiceOutput.isRecordingActive, !voiceInput.isRecording, headset.state == .idle else {
            stuckGateChecks = 0
            return
        }
        stuckGateChecks += 1
        guard stuckGateChecks >= 2 else { return }
        stuckGateChecks = 0
        dLog("recording gate was up with no recording in progress, lowering it")
        voiceOutput.isRecordingActive = false
        voiceInput.didRaiseRecordingGate = false
        flushHeldReplies()
    }

    // MARK: - Settings

    private func applyDrivingSettings() {
        savedSettings = SavedSettings(headsetModeEnabled: settings.headsetModeEnabled,
                                      blueParrottEnabled: settings.blueParrottEnabled,
                                      audibleCuesEnabled: settings.headsetAudibleCuesEnabled,
                                      muted: voiceOutput.isMuted)
        // The mode is useless without a button source. If one is already
        // chosen, leave the choice alone; if none is, turn both on rather than
        // guess which headset this is.
        if !settings.headsetModeEnabled && !settings.blueParrottEnabled {
            dLog("no headset button source was on, enabling BlueParrott and media keys")
            settings.blueParrottEnabled = true
            settings.headsetModeEnabled = true
        }
        // With no eyes on the screen the tones are the only feedback that a
        // press registered.
        if !settings.headsetAudibleCuesEnabled { settings.headsetAudibleCuesEnabled = true }
        if voiceOutput.isMuted { voiceOutput.isMuted = false }
    }

    private func restoreSettings() {
        guard let saved = savedSettings else { return }
        savedSettings = nil
        if settings.headsetModeEnabled != saved.headsetModeEnabled { settings.headsetModeEnabled = saved.headsetModeEnabled }
        if settings.blueParrottEnabled != saved.blueParrottEnabled { settings.blueParrottEnabled = saved.blueParrottEnabled }
        if settings.headsetAudibleCuesEnabled != saved.audibleCuesEnabled { settings.headsetAudibleCuesEnabled = saved.audibleCuesEnabled }
        if voiceOutput.isMuted != saved.muted { voiceOutput.isMuted = saved.muted }
    }

    // MARK: - Speech

    /// Say a status line. Queued, so it never cuts off a reply being read.
    private func announce(_ text: String) {
        dLog("announce: \(text)")
        voiceOutput.enqueue(text)
    }

    private func entryAnnouncement() -> String {
        var parts = ["Driving mode on."]
        if sessionId == nil {
            parts.append("No session to drive. Pick one on the laptop.")
        } else if !sessionName.isEmpty {
            parts.append("\(sessionName).")
        }
        if !client.isConnected {
            parts.append("Not connected to the server yet.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Session choice

    /// The session to drive: `preferred` if it exists, else the active one, else
    /// the one driven last time, else the most recently used.
    static func resolveSession(preferred: UUID?,
                               active: UUID?,
                               persisted: UUID?,
                               in context: NSManagedObjectContext) -> CDBackendSession? {
        for candidate in [preferred, active, persisted] {
            guard let id = candidate else { continue }
            if let session = try? context.fetch(CDBackendSession.fetchBackendSession(id: id)).first {
                return session
            }
        }
        return try? CDBackendSession.mostRecentActiveSession(context: context)
    }

    /// A name worth saying aloud. A session nobody named is called by its
    /// identifier, which is noise when spoken, so its folder is used instead.
    static func readableName(for session: CDBackendSession, in context: NSManagedObjectContext) -> String {
        let name = session.displayName(context: context)
        guard UUID(uuidString: name) != nil || name.isEmpty else { return name }
        let folder = (session.workingDirectory as NSString).lastPathComponent
        return folder.isEmpty ? "Unnamed session" : "Session in \(folder)"
    }
}
#endif
