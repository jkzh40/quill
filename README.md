# quill

A fully local macOS CLI meeting recorder with live transcription and speaker
diarization. It records the microphone and system audio as separate tracks,
while an in-memory actor continuously mirrors the current transcript to JSON.
Nothing leaves the Mac.

Named for the feather. Sibling of
[parrot](https://github.com/digimata/parrot): one Swift binary and no app
bundle.

## Install

```sh
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
```

Requires macOS 15+ and Apple Silicon. Core Audio process taps capture system
audio without a virtual device or kernel extension.

## Recording

Run `quill` to begin recording and press `Ctrl-C` to stop. Before capture
starts, Quill loads all three speech models; a download or model-load failure
blocks the recording instead of silently producing an untranscribed meeting.
Stopping flushes the final speech episode and finalizes speaker assignments.

Each session is stored under `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | Microphone audio |
| `system.caf` | Everything played by the Mac |
| `meta.json` | Lifecycle, timestamps, track files, and start offsets |
| `transcript.json` | Authoritative live transcript state |
| `transcribe.log` | Recovery and hook errors, when present |

There is intentionally no generated Markdown transcript. Consumers should
read `transcript.json`, whose atomic replacement means they see either the
previous complete snapshot or the next one, never a partially written file.

## Live transcription

The same pipeline handles live recording and interrupted-session recovery:

1. FluidAudio converts each track to 16 kHz mono.
2. Silero VAD opens an acoustic speech episode at probability 0.50 and closes
   it after probability falls below 0.35 for 750 ms. Regions shorter than 300
   ms are ignored and receive 100 ms speech padding.
3. Parakeet TDT 0.6B v2 transcribes 14-second processing windows with two
   seconds of overlap. These windows never split the containing episode.
   Results below confidence 0.65 remain as window diagnostics but do not become
   words; accepted overlap words are reconciled by text and timestamp. Quill
   never fabricates a full-window word when token timings are missing or every
   timed word was already seen.
4. LS-EEND DIHARD3 runs continuously at 100 ms resolution on both tracks.
   Speaker identities are track-scoped (`mic:speaker-1`,
   `system:speaker-2`), so Quill does not claim that a voice heard on both
   tracks is the same person.
5. `TranscriptStore`, a Swift actor, owns the typed facts. It reprojects words
   whenever diarization evidence changes and derives turns independently of
   processing windows. The same speaker can continue across episodes separated
   by up to two seconds, while another speaker taking the floor starts a new
   turn. The store atomically writes at most four JSON snapshots per second.

Schema v2 contains lifecycle, model and policy provenance, tracks, VAD
`episodes`, diagnostic `processing_windows`, accepted ASR words, diarization
spans, speaker candidates, and derived turns. The legacy `utterances` array and
`utterance_id` fields remain as processing-window compatibility views. Word
facts are stable; speaker attribution can move from `pending` or `tentative` to
a corrected final speaker without append-only coordination. Overlapping
candidates remain available on each word. Completed schema-v1 sessions remain
readable and are not rewritten automatically.

On a clean stop, status becomes `complete`. If Quill exits with a nonterminal
snapshot, the next invocation replays any readable CAF tracks through the same
pipeline concurrently with the new recording and waits for recovery before
exiting. Legacy transcripts with the old `segments` schema are treated as
already complete.

## CLI

```sh
quill                       # record; live transcript on stdout; Ctrl-C to stop
quill --out <dir>           # record under a custom root
quill --no-transcribe       # audio only; no model load or transcript JSON
quill record [options]      # equivalent explicit subcommand
quill doctor                # permissions, output folder, and model caches
```

Progress and paths go to stderr. Each accepted processing-window delta is
printed once to stdout as a tentative convenience stream:

```text
[0:12–0:18] system:speaker-2? I think the first approach is better.
```

Later speaker corrections update only `transcript.json`; stdout is deliberately
not rewritten. Pipe it anywhere a line-oriented preview is useful, while using
the session JSON for durable processing.

## Local structural regression

The model-backed regression suite is opt-in and never runs in CI. It seeks
directly into a local session's CAF files; no meeting audio or transcript text
is committed or copied into the repository:

```sh
QUILL_REGRESSION_SESSION="/path/to/session" \
  swift test --filter LocalSessionRegression.curatedStructuralFixtures
```

The curated suite checks forced-window duplication, quiet-tail false positives,
short genuine speech, cross-track input, episode/window provenance, and turn
fragmentation. Aggregate JSON and Markdown reports are written under
`.build/quill-regression/`. Add `QUILL_REGRESSION_FULL=1` and select
`LocalSessionRegression.fullSessionStructuralReport` to replay the entire
session. These tests measure structural fidelity, not word or speaker error
rates; those require human reference annotations.

## Models and dependencies

FluidAudio is an external Apache-2.0 open-source Swift package, not an
Apple-shipped framework. Quill uses its Core ML ports of Parakeet, Silero VAD,
and LS-EEND. Apple supplies the Core ML runtime and AVFoundation/Core Audio
capture APIs. The speech model files download into FluidAudio's local
Application Support cache before the first transcribed recording.

Parakeet v2 is English-only. LS-EEND supports up to 10 speakers; Quill
preserves all model speaker indices and does not perform cross-track voice
matching.

## Config

Optional config lives at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true },
  "mic_voice_processing": false,
  "on_stop": "my-hook"
}
```

- `recordings_dir`: output root. `--out` takes precedence.
- `transcription.enabled`: set to `false` for audio-only recording.
- `mic_voice_processing`: Apple echo cancellation for meetings played through
  speakers. It can slightly duck other playback, so it defaults to `false`.
- `on_stop`: shell command invoked with the session directory after the JSON
  reaches `complete`, or immediately after an audio-only recording stops.

## Stack

- Swift and Swift Package Manager
- Core Audio process taps for system audio
- AVAudioEngine and AVAudioFile for capture
- FluidAudio with Parakeet, Silero VAD, and LS-EEND for local speech processing
- Core ML for model execution

The global system tap records every sound the Mac plays, including notification
sounds and music. If a track is silent, check **System Settings → Privacy &
Security → Microphone** and **Screen & System Audio Recording**.
