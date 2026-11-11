# Kokoro voice on the iPhone

The iPhone app reads replies with Kokoro-82M (voice `af_heart`) instead of `AVSpeechSynthesizer`.
Apple's voice stays as the fallback, and Settings can switch back to it. The Mac app is unchanged.

Why Kokoro: in a blind listening test (2026-11-09) of five voices reading five real replies, Travis
picked Kokoro `af_heart` first, ahead of Ming 0.5B, Phonon 31m, Pocket TTS and Apple's Ava (Premium).

## Choices

| Question | Choice | Why |
|---|---|---|
| Runtime | [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.3, `KokoroAneManager` (Core ML, legacy seven-stage chain), pinned exactly | Apache-2.0, maintained, Swift API, English frontend included. On iOS 27 its default routing is Metal-free: five stages on CPU + Neural Engine, noise and tail on CPU. |
| Phonemizer | FluidAudio's Kokoro English frontend: NeMo text normalization, then the Misaki lexicon, then a small BART G2P model for words the lexicon lacks | The same lexicon the reference renders used, with no espeak-ng anywhere. |
| Model delivery | Downloaded on first use (91 MB on disk, measured; FluidAudio's table says 0.33 GB) into Application Support, excluded from iCloud backup | Keeps the app small and device deploys fast. Downloads only on Wi-Fi unless Travis taps **Download now**. |
| Voice, speed | `af_heart`, speed 1.0 at the app's default rate (0.5) | Exactly voice E of the listening test. |

Rejected: bundling the model (about 90 MB more per deploy over the local network, and on every TestFlight build), MLX ports (GPU only, and iOS blocks
background GPU), sherpa-onnx and Piper (link espeak-ng, GPL), a Mac-side render endpoint (works, but the brief
was to build the voice into the phone app; it stays the fallback plan if on-device Kokoro proves unstable).

## Licences

- Kokoro-82M weights, FluidAudio's Core ML conversion (`FluidInference/kokoro-82m-coreml`), the Misaki lexicon:
  Apache-2.0. NeMo text processing (`text-processing-rs`, linked as an xcframework): Apache-2.0, with rustfst
  (MIT/Apache-2.0).
- **GPL guard.** FluidAudio's `TTS` trait also bundles LuxTTS resources (`luxtts_en_us_lexicon.tsv.zz`,
  `luxtts_en_us_g2p_aux.json`) that FluidAudio documents as generated from espeak-ng output and dictionary
  sources, GPL-3.0-or-later. Kokoro never reads them. A post-build phase on the iOS target deletes
  `FluidAudio_LuxTtsG2pResources.bundle` from the app and fails the build if any LuxTTS data file is still in
  the product, so they never ship. FluidAudio's Swift code for LuxTTS is its own Apache-2.0 reimplementation
  and contains no espeak-ng code.

## Fitting the speech queue

`VoiceOutputManager` owns the queue, the generation tags, the per-session cancel and the audio-session
plan, all keyed on `AVSpeechUtterance` identity and on the three delegate callbacks. None of that changes.
`SpeechSynthesizerRouter` replaces its `AVSpeechSynthesizer` with the same surface (`speak`, `stopSpeaking`,
`pauseSpeaking`, `continueSpeaking`, `isSpeaking`, `delegate`) and reports `didStart`, `didFinish` and
`didCancel` for the **same utterance object** the manager handed it, whichever engine read it.

Per utterance, the router uses Kokoro when it is selected and loaded, otherwise Apple. So replies that arrive
while the model is downloading or loading are read by Apple, as today.

**Fallback.** If Kokoro fails partway (synthesis error, first audio not ready in 6 s, a chunk stalled for 10 s,
a player error), the router reads the unread remainder with Apple's voice, using the voice and rate already
resolved on the utterance. The manager still sees one utterance: one `didStart`, then `didFinish` or
`didCancel`.

**Playback.** Text gets the markdown cleanup the listening test used (no `**`, heading marks, bullet dashes or
link URLs), then splits like the reference render: one chunk per line, long lines at sentence ends (at most
about 380 characters), with the first sentence on its own so audio starts sooner. Each chunk is synthesized in
order as fast as the model goes, and played with its own `AVAudioPlayer` (not `AVAudioEngine`, which resets on
the route changes headset `.playAndRecord` causes), with 0.3 s after a line and 0.12 s after a sentence. The
whole reply is usually synthesized within seconds, so locking the phone mid-reply does not interrupt it. A call
or other interruption pauses the player; playback carries on when the interruption ends (Apple's voice takes
over if the player will not restart). Kokoro's output is raised about 7 dB, with a soft limiter on the peaks,
because it measured −25.4 LUFS against −18.0 for Apple's Ava (Premium) on the same reply.

**Explicit Apple speech.** `speakWithAppleVoice` reads one utterance with Apple whatever the setting, for the
Apple voice preview in Settings.

## Risks and guards

- **Uncatchable Core ML crashes on iOS 27.** FluidAudio's `initialize()` warns that no Kokoro Core ML route is
  proven safe for long sessions on iOS 27 (a `libBNNS vadd_fp16_sme` crash after about an hour on an iPhone 17
  Pro, FluidAudio #889, closed after iOS 27.2). The A17 Pro has no SME. Guard: a flag is set in
  `UserDefaults` around every synthesis call. If the app starts and finds it still set, the last run died
  mid-synthesis. After two such starts in a row Kokoro turns itself off, Settings says so, and one tap turns
  it back on. A successful synthesis resets the count.
- **Background Neural Engine.** iOS 27 requires the `com.apple.developer.background-tasks.continued-processing.inference`
  entitlement for Neural Engine work from a background app. A reply that arrives with the screen locked is
  synthesized in the background; without the entitlement that can fail, and the router then reads it with
  Apple's voice. Replies that start in the foreground are synthesized before the lock bites.
- **Memory.** The loaded model costs several hundred MB. On a memory warning while idle, the model is unloaded
  and reloaded the next time the app becomes active; in between, Apple reads.

## Settings (iPhone)

A **Voice engine** section above the Apple voice picker: *Kokoro (Heart)* or *Apple*, Kokoro's status
(waiting for Wi-Fi, downloading, loading, ready, failed, turned off after crashes) with Download now / Retry /
Turn back on, and a Kokoro preview. The Apple picker becomes the fallback voice when Kokoro is selected.

## Measured (2026-11-11)

| | Result | Where |
|---|---|---|
| App size, Release arm64 | 7.7 → 27.4 MB installed, 4.2 → 13.7 MB zipped. Of the added code, NeMo text normalization is 8.0 MB and FluidAudio's Swift 5.8 MB. | Link map |
| Model, first use | 91 MB on disk | Mac, simulator |
| Speed, warm | 16–40× faster than real time; first line ready in 0.17 s | M4 Max (Neural Engine) |
| First synthesis after load | 0.8 s, hence the warm-up at load | M4 Max |
| End to end through `KokoroPlayback` | Audio started 0.82 s after the request and a 44 s reply played to the end; synthesis about 2.5× faster than real time on CPU alone | iOS 18.6 simulator (no Neural Engine) |
| Memory | Simulator: 343 MB footprint once loaded, 611 MB after synthesis, peak 1.19 GB. Mac: about 1.0 GB resident, peak footprint 2.0 GB | |
| Length of the listening-test texts | 109 s and 154 s, against 107 s and 150 s for voice E | M4 Max |

The iPhone figures come from the self-test below.

## Verification

- Unit tests: the router (engine choice, callbacks reported for the original utterance, fallback of the
  remainder, cancel, pause, a new utterance preempting Kokoro), the text chunker, the crash guard.
- Existing `VoiceOutputManagerTests` run unchanged: tests never load the model, so the router reads with Apple.
- On the iPhone 15 Pro: a debug self-test (launch argument `-KokoroSelfTest`) loads the model, synthesizes
  sample replies without playing them, and writes load time, time to first audio, real-time factor and memory
  footprint to `Documents/kokoro-selftest.json`.
