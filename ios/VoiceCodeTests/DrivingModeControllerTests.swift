// DrivingModeControllerTests.swift
// The Mac driving mode's controller: what it takes over on entry, gives back on
// exit, and puts right again on every health check. Driven with spies for the
// client, speech and power, an in-memory store, and a clock the test moves, so
// an hours-long drive is a few function calls. See notes/mac-driving-mode.md.

#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import CoreData
import CoreBluetooth
import Combine
@testable import VoiceCode

private final class DrivingClientSpy: VoiceCodeClient {
    var subscribed: [String] = []
    var forceReconnectCount = 0

    override func subscribe(sessionId: String, context: NSManagedObjectContext? = nil) {
        subscribed.append(sessionId)
    }
    override func forceReconnect() { forceReconnectCount += 1 }
    override func sendMessage(_ message: [String: Any]) {}
}

private final class DrivingVoiceSpy: VoiceOutputManager {
    var enqueued: [String] = []
    var replayed: [String] = []

    override func enqueue(_ text: String, rate: Float = 0.5, respectSilentMode: Bool = false,
                          workingDirectory: String? = nil, sessionId: UUID? = nil) {
        enqueued.append(text)
    }
    override func replay(_ text: String, rate: Float = 0.5, workingDirectory: String? = nil,
                         sessionId: UUID? = nil) -> Bool {
        replayed.append(text)
        return true
    }
}

private final class PowerSpy: DrivingPowerAssertion {
    private(set) var isHeld = false
    private(set) var beginCount = 0
    func begin(reason: String) { isHeld = true; beginCount += 1 }
    func end() { isHeld = false }
    /// The system dropped the assertion behind the app's back.
    func drop() { isHeld = false }
}

private final class InertBLECentral: BLECentral {
    var managerState: CBManagerState = .poweredOn
    weak var centralDelegate: BLECentralEvents?
    var connectedPeripheralIdentifier: UUID?
    func scanForButtonService() {}
    func stopScan() {}
    func resolveKnownPeripheral(_ id: UUID) {}
    func connectAdvertised() {}
    func connectKnown() {}
    func reconnectHeld() {}
    func cancelConnection() {}
    func subscribeToButtonEvents() {}
    func writeAppModeEnable(_ payload: Data) {}
}

final class DrivingModeControllerTests: XCTestCase {

    private static let defaultsKeys = [
        "drivingModeEnabled", "drivingReplayCount", "drivingSessionId", "drivingKeepOnTop",
        "headsetModeEnabled", "blueParrottEnabled", "headsetAudibleCuesEnabled",
        "blueParrottPeripheralID", "voiceOutputMuted"
    ]

    private var settings: AppSettings!
    private var voice: DrivingVoiceSpy!
    private var input: MockVoiceInputForHeadset!
    private var client: DrivingClientSpy!
    private var headset: HeadsetRemoteCommandManager!
    private var activeSession: ActiveSessionManager!
    private var persistence: PersistenceController!
    private var power: PowerSpy!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var controller: DrivingModeController!

    private var context: NSManagedObjectContext { persistence.container.viewContext }

    override func setUp() {
        super.setUp()
        Self.defaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        settings = AppSettings()
        activeSession = ActiveSessionManager()
        voice = DrivingVoiceSpy(appSettings: settings, activeSession: activeSession)
        voice.isMuted = false
        input = MockVoiceInputForHeadset(voiceOutputManager: voice)
        persistence = PersistenceController(inMemory: true)
        client = DrivingClientSpy(
            serverURL: "ws://localhost:8080",
            voiceOutputManager: voice,
            sessionSyncManager: SessionSyncManager(persistenceController: persistence, voiceOutputManager: voice),
            appSettings: settings,
            setupObservers: false)
        client.isConnected = true
        headset = HeadsetRemoteCommandManager(voiceInput: input, voiceOutput: voice, client: client, settings: settings)
        // Never stand up real CoreBluetooth, and never let a session timer fire.
        headset.makeBlueParrottBLEManager = {
            BlueParrottBLEManager(central: InertBLECentral(), scheduleWork: { _, _ in },
                                  savedIdentifier: { nil }, persistIdentifier: { _ in },
                                  clearSavedIdentifier: {})
        }
        headset.sessionScheduleWork = { _, _ in }
        headset.earconPlayer = SpyEarconPlayer()
        power = PowerSpy()
        controller = DrivingModeController(
            settings: settings, client: client, voiceOutput: voice, voiceInput: input, headset: headset,
            activeSession: activeSession,
            viewContext: { [unowned self] in self.context },
            power: power,
            now: { [unowned self] in self.clock })
        controller.startHealthTimer = { _ in AnyCancellable {} }   // tests call healthCheck() themselves
        // Most tests model a user who already chose the BlueParrott button.
        settings.blueParrottEnabled = true
        drain()
    }

    override func tearDown() {
        controller?.exit()
        drain()
        controller = nil
        headset = nil
        client = nil
        input = nil
        voice = nil
        settings = nil
        activeSession = nil
        persistence = nil
        power = nil
        Self.defaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Let main-queue work (Combine `receive(on:)` hops, async re-asserts) run.
    private func drain(_ turns: Int = 3) {
        for _ in 0..<turns {
            let done = expectation(description: "main queue drained")
            DispatchQueue.main.async { done.fulfill() }
            wait(for: [done], timeout: 2)
        }
    }

    @discardableResult
    private func makeSession(name: String = "Deploy fixes", directory: String = "/code/voice-code",
                             modified: Date = Date(), locallyCreated: Bool = false,
                             messageCount: Int32 = 4) -> UUID {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = name
        session.workingDirectory = directory
        session.lastModified = modified
        session.messageCount = messageCount
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = locallyCreated
        try? context.save()
        return session.id
    }

    @discardableResult
    private func addMessage(_ text: String, role: String = "assistant", to sessionId: UUID,
                            secondsAgo: TimeInterval) -> UUID {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = sessionId
        message.role = role
        message.text = text
        message.timestamp = clock.addingTimeInterval(-secondsAgo)
        message.messageStatus = .confirmed
        try? context.save()
        return message.id
    }

    private func announceArrival(in sessionId: UUID) {
        NotificationCenter.default.post(name: .sessionHistoryDidUpdate, object: nil,
                                        userInfo: ["sessionId": sessionId.uuidString.lowercased()])
        drain()
    }

    // MARK: - Entering

    func testEnterTakesOverTheSession() {
        let session = makeSession()

        controller.enter(preferred: session)
        drain()

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.sessionId, session)
        XCTAssertEqual(controller.sessionName, "Deploy fixes")
        XCTAssertEqual(activeSession.activeSessionId, session, "replies are only read for the active session")
        XCTAssertTrue(client.subscribed.contains(session.uuidString.lowercased()))
        XCTAssertTrue(power.isHeld, "the Mac must stay awake for the drive")
        XCTAssertTrue(settings.drivingModeEnabled, "persisted, so a relaunch comes back in the mode")
        XCTAssertEqual(settings.drivingSessionId, session)
    }

    func testEnterSaysItIsOnAndWhichSession() {
        let session = makeSession(name: "Deploy fixes")

        controller.enter(preferred: session)

        XCTAssertEqual(voice.enqueued, ["Driving mode on. Deploy fixes."])
    }

    func testEnterSaysWhenThereIsNoServerConnection() {
        client.isConnected = false
        drain()
        let session = makeSession(name: "Deploy fixes")

        controller.enter(preferred: session)

        XCTAssertEqual(voice.enqueued, ["Driving mode on. Deploy fixes. Not connected to the server yet."])
    }

    func testEnterWithNoSessionAtAllSaysSo() {
        controller.enter()

        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.sessionId)
        XCTAssertEqual(voice.enqueued, ["Driving mode on. No session to drive. Pick one on the laptop."])
        XCTAssertTrue(client.subscribed.isEmpty)
    }

    func testSessionChoiceOrder() {
        let older = makeSession(name: "Older", modified: Date(timeIntervalSince1970: 100))
        let newest = makeSession(name: "Newest", modified: Date(timeIntervalSince1970: 300))
        let middle = makeSession(name: "Middle", modified: Date(timeIntervalSince1970: 200))
        let unknown = UUID()

        func chosen(preferred: UUID?, active: UUID?, persisted: UUID?) -> UUID? {
            DrivingModeController.resolveSession(preferred: preferred, active: active,
                                                 persisted: persisted, in: context)?.id
        }
        XCTAssertEqual(chosen(preferred: older, active: middle, persisted: newest), older)
        XCTAssertEqual(chosen(preferred: nil, active: middle, persisted: older), middle,
                       "with nothing named, the conversation on screen")
        XCTAssertEqual(chosen(preferred: nil, active: nil, persisted: older), older,
                       "then the session driven last time")
        XCTAssertEqual(chosen(preferred: unknown, active: unknown, persisted: unknown), newest,
                       "then the most recently used; an id that no longer exists is skipped")
    }

    func testTheMostRecentSessionSkipsOnesTheUserDeleted() throws {
        let older = makeSession(name: "Older", modified: Date(timeIntervalSince1970: 100))
        let newest = makeSession(name: "Newest", modified: Date(timeIntervalSince1970: 300))
        let middle = makeSession(name: "Middle", modified: Date(timeIntervalSince1970: 200))
        for id in [newest, middle] {
            let deleted = CDUserSession(context: context)
            deleted.id = id
            deleted.isUserDeleted = true
            deleted.createdAt = Date()
        }
        try context.save()

        XCTAssertEqual(try CDBackendSession.mostRecentActiveSession(context: context)?.id, older)
        XCTAssertEqual(DrivingModeController.resolveSession(preferred: nil, active: nil, persisted: nil, in: context)?.id, older)
        XCTAssertEqual(try CDBackendSession.fetchActiveSessions(context: context).map(\.id), [older],
                       "the full list agrees")
    }

    func testAnUnnamedSessionIsCalledByItsFolder() {
        let session = makeSession(name: UUID().uuidString.lowercased(), directory: "/Users/me/code/voice-code")
        let row = try? context.fetch(CDBackendSession.fetchBackendSession(id: session)).first

        XCTAssertEqual(row.map { DrivingModeController.readableName(for: $0, in: context) },
                       "Session in voice-code",
                       "an identifier read aloud is noise")
    }

    func testASessionTheBackendHasNeverSeenIsNotSubscribed() {
        let session = makeSession(locallyCreated: true, messageCount: 0)

        controller.enter(preferred: session)
        drain()

        XCTAssertEqual(activeSession.activeSessionId, session)
        XCTAssertTrue(client.subscribed.isEmpty, "there is no file to subscribe to until the first prompt creates it")
    }

    // MARK: - Settings taken and given back

    func testEnterTurnsOnAButtonSourceWhenNoneWasChosen() {
        settings.blueParrottEnabled = false
        drain()
        let session = makeSession()

        controller.enter(preferred: session)
        drain()

        XCTAssertTrue(settings.blueParrottEnabled)
        XCTAssertTrue(settings.headsetModeEnabled)
        XCTAssertTrue(settings.headsetAudibleCuesEnabled, "the tones are the only feedback with no eyes on the screen")

        controller.exit()
        drain()

        XCTAssertFalse(settings.blueParrottEnabled, "exit puts back what entry changed")
        XCTAssertFalse(settings.headsetModeEnabled)
        XCTAssertFalse(settings.headsetAudibleCuesEnabled)
    }

    func testEnterLeavesAChosenButtonSourceAlone() {
        let session = makeSession()   // setUp chose the BlueParrott button

        controller.enter(preferred: session)
        drain()

        XCTAssertTrue(settings.blueParrottEnabled)
        XCTAssertFalse(settings.headsetModeEnabled,
                       "turning media keys on beside a BlueParrott would be a guess about the headset")
    }

    func testEnterUnmutesAndExitRestoresTheMute() {
        voice.isMuted = true
        let session = makeSession()

        controller.enter(preferred: session)
        XCTAssertFalse(voice.isMuted, "a muted driving mode would be silent for the whole drive")

        controller.exit()
        XCTAssertTrue(voice.isMuted)
    }

    // MARK: - Leaving

    func testExitGivesBackPowerAndClearsThePersistedFlag() {
        let session = makeSession()
        controller.enter(preferred: session)
        drain()

        controller.exit()

        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(power.isHeld)
        XCTAssertFalse(settings.drivingModeEnabled)
        XCTAssertEqual(activeSession.activeSessionId, session,
                       "left active: the conversation view that reappears carries on from here")
        XCTAssertEqual(settings.drivingSessionId, session, "remembered for next time")
    }

    func testToggle() {
        let session = makeSession()
        controller.toggle(preferred: session)
        XCTAssertTrue(controller.isActive)
        controller.toggle()
        XCTAssertFalse(controller.isActive)
    }

    // MARK: - Staying wired for hours

    /// A conversation view on screen at entry is torn down afterwards, and its
    /// teardown clears the active session and unsubscribes.
    func testActiveSessionClearedByAViewTeardownIsTakenBack() {
        let session = makeSession()
        controller.enter(preferred: session)
        drain()
        client.subscribed.removeAll()

        activeSession.clearActiveSession()
        drain()

        XCTAssertEqual(activeSession.activeSessionId, session)
        XCTAssertEqual(client.subscribed, [session.uuidString.lowercased()], "and subscribed again")
    }

    func testReauthenticationResubscribes() {
        let session = makeSession()
        controller.enter(preferred: session)
        drain()
        client.subscribed.removeAll()

        client.isAuthenticated = true
        drain()

        XCTAssertEqual(client.subscribed, [session.uuidString.lowercased()])
    }

    func testHealthCheckPutsBackWhatDrifted() {
        let session = makeSession()
        controller.enter(preferred: session)
        drain()
        client.subscribed.removeAll()
        power.drop()
        voice.isMuted = true
        let tickBefore = controller.healthTick

        controller.healthCheck()

        XCTAssertTrue(power.isHeld)
        XCTAssertFalse(voice.isMuted)
        XCTAssertEqual(client.subscribed, [session.uuidString.lowercased()])
        XCTAssertEqual(controller.healthTick, tickBefore + 1, "the window pinner re-checks the window on each tick")
    }

    func testHealthCheckDoesNothingWhenTheModeIsOff() {
        makeSession()

        controller.healthCheck()

        XCTAssertFalse(power.isHeld)
        XCTAssertTrue(client.subscribed.isEmpty)
        XCTAssertEqual(controller.healthTick, 0)
    }

    /// The recording gate drops all speech while it is up. Stuck up, it would
    /// silence every reply for the rest of the drive.
    func testAStuckRecordingGateIsLowered() {
        let session = makeSession()
        controller.enter(preferred: session)
        drain()
        voice.isRecordingActive = true   // up, with no recording in progress

        controller.healthCheck()
        XCTAssertTrue(voice.isRecordingActive, "one check is not enough: a recording may be starting")
        controller.healthCheck()

        XCTAssertFalse(voice.isRecordingActive)
    }

    func testTheRecordingGateIsLeftAloneWhileRecording() {
        let session = makeSession()
        controller.enter(preferred: session)
        drain()
        input.isRecording = true
        voice.isRecordingActive = true

        controller.healthCheck()
        controller.healthCheck()
        controller.healthCheck()

        XCTAssertTrue(voice.isRecordingActive)
    }

    // MARK: - Connection

    func testALostConnectionIsRetriedForAsLongAsItTakes() {
        let session = makeSession()
        controller.enter(preferred: session)
        drain()
        voice.enqueued.removeAll()

        client.isConnected = false
        drain()
        controller.healthCheck()
        XCTAssertEqual(client.forceReconnectCount, 0, "a blip shorter than the grace period is left to the client")
        XCTAssertTrue(voice.enqueued.isEmpty)

        clock.addTimeInterval(DrivingModeController.reconnectGrace)
        controller.healthCheck()
        XCTAssertEqual(client.forceReconnectCount, 1)
        XCTAssertEqual(voice.enqueued, ["Connection lost. Retrying."])

        clock.addTimeInterval(DrivingModeController.healthInterval)
        controller.healthCheck()
        XCTAssertEqual(client.forceReconnectCount, 1, "not on every check")

        // Two hours in, still trying: the client's own retry gives up after a fixed
        // number of attempts, the mode does not.
        for _ in 0..<240 {
            clock.addTimeInterval(DrivingModeController.forcedReconnectInterval)
            controller.healthCheck()
        }
        XCTAssertEqual(client.forceReconnectCount, 241)
        XCTAssertEqual(voice.enqueued, ["Connection lost. Retrying."], "said once, not every thirty seconds")
    }

    func testReconnectingIsSaidAndTheSessionResubscribed() {
        let session = makeSession()
        controller.enter(preferred: session)
        drain()
        client.isConnected = false
        drain()
        clock.addTimeInterval(DrivingModeController.reconnectGrace)
        controller.healthCheck()
        voice.enqueued.removeAll()
        client.subscribed.removeAll()

        client.isConnected = true
        drain()

        XCTAssertEqual(voice.enqueued, ["Reconnected."])
        XCTAssertEqual(client.subscribed, [session.uuidString.lowercased()])
    }

    func testABlipNobodyWasToldAboutIsNotAnnouncedAsAReconnect() {
        let session = makeSession()
        controller.enter(preferred: session)
        drain()
        voice.enqueued.removeAll()

        client.isConnected = false
        drain()
        client.isConnected = true
        drain()

        XCTAssertTrue(voice.enqueued.isEmpty)
    }

    func testARejectedKeyIsSaidOnceAndNotHammered() {
        let session = makeSession()
        controller.enter(preferred: session)
        drain()
        voice.enqueued.removeAll()
        client.isConnected = false
        client.requiresReauthentication = true
        drain()

        for _ in 0..<5 {
            clock.addTimeInterval(DrivingModeController.forcedReconnectInterval)
            controller.healthCheck()
        }

        XCTAssertEqual(client.forceReconnectCount, 0, "a retry cannot fix a rejected key")
        XCTAssertEqual(voice.enqueued, ["The server rejected this app's key. Driving mode cannot reconnect."])
    }

    // MARK: - Replay tiles

    func testTilesAreTheNewestRepliesNewestFirst() {
        let session = makeSession()
        addMessage("First reply", to: session, secondsAgo: 400)
        addMessage("Please run the tests", role: "user", to: session, secondsAgo: 300)
        addMessage("Second reply", to: session, secondsAgo: 200)
        addMessage("Third reply", to: session, secondsAgo: 100)
        addMessage("Fourth reply", to: session, secondsAgo: 50)

        controller.enter(preferred: session)

        XCTAssertEqual(controller.replies.map(\.text), ["Fourth reply", "Third reply", "Second reply"],
                       "three by default, the driver's own prompts left out")
    }

    func testTheNumberOfTilesFollowsTheSetting() {
        let session = makeSession()
        for index in 1...6 {
            addMessage("Reply \(index)", to: session, secondsAgo: TimeInterval(700 - index * 100))
        }
        controller.enter(preferred: session)

        settings.drivingReplayCount = 5
        drain()
        XCTAssertEqual(controller.replies.count, 5)

        settings.drivingReplayCount = 1
        drain()
        XCTAssertEqual(controller.replies.map(\.text), ["Reply 6"])
    }

    func testANewReplyAppearsOnTheTopTile() {
        let session = makeSession()
        addMessage("Earlier", to: session, secondsAgo: 100)
        controller.enter(preferred: session)

        addMessage("Just arrived", to: session, secondsAgo: 0)
        announceArrival(in: session)

        XCTAssertEqual(controller.replies.map(\.text), ["Just arrived", "Earlier"])
    }

    func testAReplyInAnotherSessionDoesNotTouchTheTiles() {
        let session = makeSession()
        let other = makeSession(name: "Other")
        addMessage("Mine", to: session, secondsAgo: 100)
        controller.enter(preferred: session)

        addMessage("Someone else's", to: other, secondsAgo: 0)
        announceArrival(in: other)

        XCTAssertEqual(controller.replies.map(\.text), ["Mine"])
    }

    func testClickingATileReadsThatReplyPreparedForSpeech() {
        let session = makeSession()
        addMessage("Older reply", to: session, secondsAgo: 100)
        let newest = addMessage("Fixed `parseMessage`:\n```swift\nlet x = 1\n```\nDone.", to: session, secondsAgo: 10)
        controller.enter(preferred: session)

        controller.replay(index: 0)
        controller.replay(index: 1)
        controller.replay(index: 2)   // no third reply: nothing happens

        XCTAssertEqual(voice.replayed, ["Fixed parse Message:\n[code block]\nDone.", "Older reply"])
        XCTAssertEqual(controller.lastReplayedId, controller.replies[1].id)
        XCTAssertEqual(controller.replies[0].id, newest)
    }

    // MARK: - Replies that arrive while the microphone is open

    /// Speech is dropped while recording, so a reply that lands then is never read.
    /// The mode reads it when the microphone closes.
    func testARepliesThatArriveWhileRecordingAreReadWhenTheMicrophoneCloses() {
        let session = makeSession()
        addMessage("Already heard", to: session, secondsAgo: 100)
        controller.enter(preferred: session)
        drain()
        voice.enqueued.removeAll()

        input.isRecording = true
        voice.isRecordingActive = true
        drain()
        addMessage("Landed mid-sentence, first", to: session, secondsAgo: 2)
        announceArrival(in: session)
        addMessage("Landed mid-sentence, second", to: session, secondsAgo: 1)
        announceArrival(in: session)
        XCTAssertTrue(voice.enqueued.isEmpty, "nothing is read into an open microphone")

        voice.isRecordingActive = false
        input.isRecording = false
        drain()

        XCTAssertEqual(voice.enqueued, ["Landed mid-sentence, first", "Landed mid-sentence, second"],
                       "in the order they arrived")

        input.isRecording = true
        drain()
        input.isRecording = false
        drain()
        XCTAssertEqual(voice.enqueued.count, 2, "and only once")
    }

    func testARepliesThatArriveWithTheMicrophoneClosedAreNotReadASecondTime() {
        let session = makeSession()
        controller.enter(preferred: session)
        drain()
        voice.enqueued.removeAll()

        addMessage("Read by the normal path", to: session, secondsAgo: 0)
        announceArrival(in: session)
        input.isRecording = true
        drain()
        input.isRecording = false
        drain()

        XCTAssertTrue(voice.enqueued.isEmpty, "the sync manager already queued it; the mode must not double it")
    }

    // MARK: - Settings

    func testDrivingSettingsDefaults() {
        XCTAssertFalse(settings.drivingModeEnabled)
        XCTAssertEqual(settings.drivingReplayCount, 3)
        XCTAssertNil(settings.drivingSessionId)
        XCTAssertTrue(settings.drivingKeepOnTop)
    }

    func testDrivingSettingsPersist() {
        let session = UUID()
        settings.drivingModeEnabled = true
        settings.drivingReplayCount = 5
        settings.drivingSessionId = session
        settings.drivingKeepOnTop = false

        let reloaded = AppSettings()

        XCTAssertTrue(reloaded.drivingModeEnabled)
        XCTAssertEqual(reloaded.drivingReplayCount, 5)
        XCTAssertEqual(reloaded.drivingSessionId, session)
        XCTAssertFalse(reloaded.drivingKeepOnTop)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "drivingSessionId"), session.uuidString.lowercased(),
                       "identifiers are stored lowercase")

        settings.drivingSessionId = nil
        XCTAssertNil(AppSettings().drivingSessionId)
    }

    func testAStoredReplayCountOutOfRangeIsClamped() {
        UserDefaults.standard.set(42, forKey: "drivingReplayCount")
        XCTAssertEqual(AppSettings().drivingReplayCount, 5)
        UserDefaults.standard.set(0, forKey: "drivingReplayCount")
        XCTAssertEqual(AppSettings().drivingReplayCount, 1)
    }

    // MARK: - Keys

    func testDrivingKeys() {
        XCTAssertEqual(DrivingKey.from(characters: "1", modifiers: []), .replay(0))
        XCTAssertEqual(DrivingKey.from(characters: "3", modifiers: []), .replay(2))
        XCTAssertEqual(DrivingKey.from(characters: " ", modifiers: []), .talk)
        XCTAssertEqual(DrivingKey.from(characters: "2", modifiers: [.shift]), .replay(1))
        XCTAssertNil(DrivingKey.from(characters: "0", modifiers: []))
        XCTAssertNil(DrivingKey.from(characters: "d", modifiers: []))
        XCTAssertNil(DrivingKey.from(characters: "1", modifiers: [.command]), "a menu shortcut is not a driving key")
        XCTAssertNil(DrivingKey.from(characters: " ", modifiers: [.option]), "Option+Space is push-to-talk elsewhere")
        XCTAssertNil(DrivingKey.from(characters: nil, modifiers: []))
        XCTAssertNil(DrivingKey.from(characters: "12", modifiers: []))
    }

    func testStateLabels() {
        XCTAssertEqual(DrivingStateLabel.text(for: .idle), "READY")
        XCTAssertEqual(DrivingStateLabel.text(for: .recording), "LISTENING")
        XCTAssertEqual(DrivingStateLabel.text(for: .finalizing), "SENDING")
        XCTAssertEqual(DrivingStateLabel.text(for: .awaitingResponse), "WAITING")
        XCTAssertEqual(DrivingStateLabel.text(for: .speaking), "SPEAKING")
    }

    // MARK: - The screen

    private func hostedScreen() -> NSHostingController<AnyView> {
        NSHostingController(rootView: AnyView(
            DrivingModeView(controller: controller, client: client, settings: settings, voiceInput: input)
                .environmentObject(headset)))
    }

    /// The property the mode exists for. However much text is on the screen, the
    /// view takes the size it is given and asks for no more than a tiny fixed
    /// minimum, so its window is never pushed past the edge of the display.
    func testTheScreenNeverAsksForMoreRoomThanItIsGiven() {
        let session = makeSession(name: String(repeating: "A very long session name ", count: 40))
        let huge = String(repeating: "This reply goes on and on and on.\n", count: 3000)
        addMessage(huge, to: session, secondsAgo: 30)
        addMessage(huge, to: session, secondsAgo: 20)
        addMessage(huge, to: session, secondsAgo: 10)
        input.transcribedText = String(repeating: "dictated words ", count: 2000)
        settings.drivingReplayCount = 5
        controller.enter(preferred: session)
        drain()
        XCTAssertEqual(controller.replies.count, 3)

        let host = hostedScreen()

        for proposed in [CGSize(width: 1512, height: 944), CGSize(width: 800, height: 500), CGSize(width: 400, height: 300)] {
            let wanted = host.sizeThatFits(in: proposed)
            XCTAssertLessThanOrEqual(wanted.width, proposed.width + 0.5, "asked for more width than offered at \(proposed)")
            XCTAssertLessThanOrEqual(wanted.height, proposed.height + 0.5, "asked for more height than offered at \(proposed)")
        }
        let minimum = host.sizeThatFits(in: CGSize(width: 1, height: 1))
        XCTAssertEqual(minimum.width, DrivingModeLayout.minimumSize.width, accuracy: 0.5)
        XCTAssertEqual(minimum.height, DrivingModeLayout.minimumSize.height, accuracy: 0.5,
                       "the minimum does not depend on what is being shown")
    }

    private func makeWindow(_ host: NSHostingController<AnyView>, frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        drain()
        return window
    }

    private func close(_ window: NSWindow) {
        window.contentViewController = nil
        window.close()
    }

    /// In a real window: entering the mode puts the window on the visible screen
    /// whatever it was before, and at any size the click targets are inside it and,
    /// between them, cover everything below the status strip from edge to edge.
    func testTheWindowIsPinnedAndEveryClickTargetIsInsideIt() throws {
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame, "no display to lay a window out on")
        let session = makeSession()
        addMessage(String(repeating: "Long reply. ", count: 2000), to: session, secondsAgo: 10)
        controller.enter(preferred: session)
        drain()
        let host = hostedScreen()

        // The reported failure, as the starting point: a window taller than the
        // screen, its bottom edge (where the microphone button was) below it.
        let grownOffScreen = CGRect(x: visible.minX + 40, y: visible.minY - 600, width: 700, height: visible.height + 500)
        let window = makeWindow(host, frame: grownOffScreen)
        defer { close(window) }

        XCTAssertEqual(window.frame, visible, "entering driving mode fills the visible screen")
        XCTAssertEqual(window.level, .floating, "and keeps the window above other apps' windows")

        let insideSizes = [visible.size,
                           CGSize(width: min(900, visible.width), height: min(560, visible.height)),
                           DrivingModeLayout.minimumSize]
        for size in insideSizes {
            window.setFrame(CGRect(origin: visible.origin, size: size), display: true)
            host.view.layoutSubtreeIfNeeded()
            drain()
            XCTAssertEqual(window.frame.size, size, "a window inside the screen is left at the size it was given")

            let bounds = host.view.bounds
            XCTAssertEqual(bounds.height, size.height, accuracy: 1, "the content does not make the window taller")
            let targets = Self.descendants(of: host.view).compactMap { $0 as? FirstClickNSView }
            XCTAssertEqual(targets.count, 4, "three replay tiles and the talk bar at \(size)")
            var covered: CGFloat = 0
            for target in targets {
                let frame = target.convert(target.bounds, to: host.view)
                XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(frame),
                              "'\(target.label)' is outside the window at \(size): \(frame)")
                XCTAssertEqual(frame.width, size.width, accuracy: 1, "every target spans the full width")
                covered += frame.height
            }
            let bands = DrivingModeLayout.bands(in: size, replayCount: 3)
            XCTAssertEqual(covered, size.height - bands.status.height, accuracy: 2,
                           "the targets cover everything below the status strip at \(size)")
        }

        // Pushed off the screen again mid-drive (a display change, a stray drag):
        // it is put back without anyone asking.
        window.setFrame(grownOffScreen, display: true)
        drain()
        XCTAssertFalse(DrivingModeLayout.needsRepin(frame: window.frame, visibleFrame: visible),
                       "the window was left partly off-screen: \(window.frame)")

        // Moved without changing size, half off the right-hand edge. Whether or not
        // the move was announced, the next health check finds it and puts it back.
        window.setFrameOrigin(CGPoint(x: visible.maxX - 100, y: visible.minY))
        controller.healthCheck()
        settle(host)
        XCTAssertFalse(DrivingModeLayout.needsRepin(frame: window.frame, visibleFrame: visible),
                       "the window was left partly off-screen after a health check: \(window.frame)")
    }

    /// Give SwiftUI a few run-loop turns to apply a state change to the hosted view.
    private func settle(_ host: NSViewController) {
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.view.layoutSubtreeIfNeeded()
        }
        drain()
    }

    /// Leaving the mode gives the window back its frame and level. Driven on the
    /// pinner itself, which enters a window when the driving screen appears in it
    /// and leaves when the screen goes.
    func testLeavingTheModeRestoresTheWindow() throws {
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let before = CGRect(x: visible.minX + 60, y: visible.minY + 60, width: 640, height: 420)
        let window = NSWindow(contentRect: before, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: CGRect(origin: .zero, size: before.size))
        window.contentView = content
        let pinner = DrivingPinnerNSView()

        content.addSubview(pinner)
        XCTAssertEqual(window.frame, visible)
        XCTAssertEqual(window.level, .floating)

        pinner.removeFromSuperview()
        XCTAssertEqual(window.frame, before)
        XCTAssertEqual(window.level, .normal)
    }

    func testKeepOnTopOffLeavesTheWindowLevelAlone() throws {
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let window = NSWindow(contentRect: CGRect(x: visible.minX, y: visible.minY, width: 500, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: .zero)
        window.contentView = content
        let pinner = DrivingPinnerNSView()
        pinner.keepOnTop = false

        content.addSubview(pinner)

        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.frame, visible, "the window is still put on the screen")
        pinner.removeFromSuperview()
    }

    /// A window that was already off-screen before the mode is not sent back there.
    func testLeavingDoesNotRestoreAFrameThatWasOffScreen() throws {
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let offScreen = CGRect(x: visible.minX + 40, y: visible.minY - 600, width: 700, height: visible.height + 500)
        let window = NSWindow(contentRect: offScreen, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: .zero)
        window.contentView = content
        let pinner = DrivingPinnerNSView()

        content.addSubview(pinner)
        pinner.removeFromSuperview()

        XCTAssertEqual(window.frame, visible)
    }

    func testClickingATargetOnTheScreenReplaysOrTalks() {
        let session = makeSession()
        addMessage("Newest", to: session, secondsAgo: 10)
        addMessage("Older", to: session, secondsAgo: 20)
        controller.enter(preferred: session)
        drain()
        let host = hostedScreen()
        let window = makeWindow(host, frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        defer { close(window) }
        let targets = Self.descendants(of: host.view).compactMap { $0 as? FirstClickNSView }
        func target(_ label: String) -> FirstClickNSView? { targets.first { $0.label == label } }

        XCTAssertEqual(target("Replay latest reply")?.accessibilityPerformPress(), true)
        XCTAssertEqual(target("Replay one before")?.accessibilityPerformPress(), true)
        XCTAssertEqual(voice.replayed, ["Newest", "Older"])

        XCTAssertEqual(target("Replay latest reply")?.acceptsFirstMouse(for: nil), true,
                       "one click must be enough even when another app is in front")

        XCTAssertEqual(target("Talk")?.accessibilityPerformPress(), true)
        drain()
        XCTAssertTrue(input.startRecordingCalled, "the talk bar goes through the same path as the headset button")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func testTheReplyPreviewIsShortAndOnOneLine() {
        let long = RecentReply(id: UUID(), text: String(repeating: "word\n", count: 5000), spokenText: "", timestamp: Date())
        let short = RecentReply(id: UUID(), text: "Two\nlines", spokenText: "", timestamp: Date())

        // A private view's static, reached through the module: the tile lays out a
        // bounded preview, not the whole reply.
        XCTAssertLessThanOrEqual(DrivingReplyPreview.text(of: long).count, DrivingReplyPreview.length + 1)
        XCTAssertTrue(DrivingReplyPreview.text(of: long).hasSuffix("…"))
        XCTAssertEqual(DrivingReplyPreview.text(of: short), "Two lines")
    }

    func testRepliesAlreadyThereAtEntryAreHistoryNotArrivals() {
        let session = makeSession()
        addMessage("Old news", to: session, secondsAgo: 500)
        voice.isRecordingActive = true

        controller.enter(preferred: session)
        drain()
        voice.enqueued.removeAll()
        voice.isRecordingActive = false
        input.isRecording = true
        drain()
        input.isRecording = false
        drain()

        XCTAssertTrue(voice.enqueued.isEmpty)
    }
}
#endif
