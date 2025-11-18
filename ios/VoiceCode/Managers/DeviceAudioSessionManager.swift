import Foundation
import AVFoundation

/// Configures audio session to respect the device's silent/vibrate mode
///
/// iOS doesn't provide a direct API to detect the ringer switch position.
/// Instead, we configure AVAudioSession with the appropriate category that
/// automatically respects the silent switch.
class DeviceAudioSessionManager {

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
