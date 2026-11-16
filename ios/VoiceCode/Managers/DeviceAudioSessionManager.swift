import Foundation
import AVFoundation

/// Configures audio session to respect the device's silent/vibrate mode
///
/// iOS doesn't provide a direct API to detect the ringer switch position.
/// Instead, we configure AVAudioSession with the appropriate category that
/// automatically respects the silent switch.
class DeviceAudioSessionManager {

    /// How `VoiceOutputManager` should leave the audio session for one utterance.
    /// Chosen by `speechSessionPlan(...)`, which is a pure function of the user's
    /// settings plus the current output route — so the decision is testable without
    /// a live audio route, and there is exactly one place that makes it.
    enum SpeechSessionPlan: Equatable {
        /// `.ambient` — iOS silences this category when the ringer switch is on
        /// silent/vibrate. The only lever we have on the switch, since its position
        /// is not readable from any API.
        case respectSilentSwitch
        /// `.playback` — plays regardless of the ringer switch.
        case forcePlayback
        /// Speak under the session `HeadsetRemoteCommandManager` owns — `.playAndRecord`,
        /// which already ignores the ringer switch. Normally a no-op on the category,
        /// because changing it makes iOS re-evaluate the Now Playing slot and costs us
        /// AVRCP stem-press delivery. Only correct when we've already decided this
        /// utterance is allowed to make noise.
        case useHeadsetSession
    }

    /// Output ports that mean the sound goes into ONE PERSON'S EAR, or into a car they
    /// are driving — not into a room. The ringer switch is a statement about the room,
    /// so it does not gag these.
    ///
    /// Deliberately excluded, because they are rooms and usually shared ones:
    /// `.airPlay` (a HomePod or Apple TV), `.HDMI` (a television), `.lineOut` (a dock or
    /// desk speaker). Letting those through would be strictly worse than honoring the
    /// switch — "phone on silent, casting to the living-room speaker, agent reply read
    /// out to everyone" is a louder version of the bug this table exists to fix.
    ///
    /// `.bluetoothA2DP` is knowingly permissive: iOS reports it for a JBL on a
    /// conference table exactly as it does for AirPods, and no API distinguishes them.
    /// That is the residual risk of the whole route-based rule, and the Settings
    /// caption discloses it.
    ///
    /// Anything not listed counts as the room and the switch wins — `.builtInSpeaker`,
    /// `.builtInReceiver`, and any port a future iOS adds. The default has to fall that
    /// way: the failure being guarded against is a phone talking out loud in a meeting.
    static let privateListeningPorts: Set<AVAudioSession.Port> = [
        .headphones,
        .bluetoothA2DP,
        .bluetoothHFP,
        .bluetoothLE,
        .carAudio,
        .usbAudio
    ]

    /// Pure classification of a route's output ports. The caller passes a single
    /// snapshot of `currentRoute.outputs` so the decision and the log line that
    /// explains it can never disagree.
    ///
    /// An empty route (possible before the session has ever been activated) contains
    /// no private port, so it resolves to "the room" and the switch wins.
    static func isPrivateListening(outputPorts: [AVAudioSession.Port]) -> Bool {
        outputPorts.contains { privateListeningPorts.contains($0) }
    }

    /// Decide how to leave the session for one utterance.
    ///
    /// - `respectSilentModeRequested`: this call site is automatic speech (a response
    ///   arriving). Manual "Read Aloud" passes false — the user just asked out loud.
    /// - `userRespectsSilentMode`: the "Keep quiet when the phone is on vibrate" setting.
    /// - `outputIsPrivateListening`: see `privateListeningPorts`.
    /// - `headsetModeEnabled`: headset control owns the session. The returned
    ///   `.useHeadsetSession` ENSURES that session rather than assuming it — see
    ///   `configureAudioSessionForHeadsetPlayback`. Deciding from the setting and
    ///   repairing in the executor is what makes this safe; an earlier cut decided from
    ///   the live category instead, which silently fell through to `.playback` and threw
    ///   away the Bluetooth output options whenever the category had drifted.
    ///
    /// Staying quiet is decided FIRST and independently of headset mode. That ordering
    /// is the fix for the vibrate bug: headset mode used to short-circuit the whole
    /// decision, so the switch was a no-op for every headset user even with the phone
    /// routed to its own speaker.
    ///
    /// Note that `.respectSilentSwitch` means `.ambient`, which iOS silences on SCREEN
    /// LOCK as well as on the ringer switch — so it overrides `continuePlaybackWhenLocked`
    /// for the duration of that utterance. The two settings cannot both be honored: the
    /// only category iOS silences for the switch is also the one it silences on lock.
    /// Quiet wins, because the cost of being wrong the other way is noise in a meeting.
    static func speechSessionPlan(respectSilentModeRequested: Bool,
                                  userRespectsSilentMode: Bool,
                                  headsetModeEnabled: Bool,
                                  outputIsPrivateListening: Bool) -> SpeechSessionPlan {
        let mustStayQuiet = respectSilentModeRequested
            && userRespectsSilentMode
            && !outputIsPrivateListening
        if mustStayQuiet { return .respectSilentSwitch }
        return headsetModeEnabled ? .useHeadsetSession : .forcePlayback
    }

    /// Put the session where headset control wants it, touching as little as possible.
    ///
    /// Two things this must NOT assume. First, that the category alone means the session
    /// is usable: the category survives deactivation, and `HeadsetRemoteCommandManager`
    /// deliberately leaves the session unrestored when an interruption ends without
    /// `.shouldResume` — so `.playAndRecord` can be set while the session is inactive and
    /// the utterance would be silent. Hence the unconditional `setActive(true)`.
    ///
    /// Second, that it knows the right options. When the category is already
    /// `.playAndRecord` the options belong to the headset manager — a BlueParrott session
    /// carries `.allowBluetoothHFP` for its mic — so they are left untouched. Only a
    /// drifted category is rebuilt, with the A2DP baseline
    /// (`VoiceInputManager.recordingCategoryOptions(prefersBluetoothHFP: false)`); the
    /// headset manager re-asserts its full options on the next speech end.
    func configureAudioSessionForHeadsetPlayback() throws {
        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.category != .playAndRecord {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        }
        try audioSession.setActive(true, options: [])
    }

    /// Configures the audio session to respect silent mode
    /// Call this before playing speech to ensure silent switch is honored
    func configureAudioSessionForSilentMode() throws {
        let audioSession = AVAudioSession.sharedInstance()

        // Use .ambient category which:
        // 1. Respects the hardware silent switch (no audio when switch is on)
        // 2. Allows audio to play alongside other apps' audio
        // 3. Is silenced by screen lock
        //
        // This is different from .playback which ignores the silent switch
        try audioSession.setCategory(.ambient, mode: .spokenAudio, options: [])
        try audioSession.setActive(true, options: [])
    }

    /// Configures the audio session to ignore silent mode (force playback)
    /// Used when the user setting disables silent mode respect
    func configureAudioSessionForForcedPlayback() throws {
        let audioSession = AVAudioSession.sharedInstance()

        // Use .playback category which:
        // 1. Ignores the hardware silent switch (plays even when switch is on)
        // 2. Silences other apps' audio
        // 3. Can continue when screen is locked (if continuePlaybackWhenLocked is true)
        try audioSession.setCategory(.playback, mode: .spokenAudio, options: [])
        try audioSession.setActive(true, options: [])
    }
}
