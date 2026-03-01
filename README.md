# Hands-Free Lift Logger (Whis)

MVP iPhone + watchOS companion for fast set logging with push-to-talk voice commands.

## Features

- Local-only logging with SwiftData.
- Start workout, choose exercise, log sets quickly.
- Push-to-talk voice commands (iOS and watch).
- Optional always-listening mode on iOS with configurable wake word (`Lift`, `Whis`, `Logger`, `Ready`).
- Optional spoken confirmations (configurable voice on iOS).
- Rule-based parser (no LLM, no backend).
- Clear command confirmation toast on iPhone and watch.
- Watch haptics: success (single), error (double).
- WatchConnectivity sync (phone is source of truth).

## Requirements

- iOS device for Speech recognition testing.
- Watch app target paired with the iOS app.
- Xcode 16+ and iOS/watchOS SDKs with SwiftData and Testing framework.

## Permissions

Add these to the iOS app target Info settings:

- `NSSpeechRecognitionUsageDescription`: "Speech is used to log workout commands."
- `NSMicrophoneUsageDescription`: "Microphone is used for push-to-talk workout commands."

If using watch speech locally, mirror microphone/speech permissions in watch target settings.

## Voice Commands

Examples:

- `weight 80`
- `80 kg`
- `8 reps`
- `reps 8`
- `done`
- `done 8`
- `next`
- `previous`
- `rest 90`
- `rest 2 minutes`
- `stop rest`
- `undo`
- `clear`
- `exercise squat`

Ambiguous number rule:

- Bare number like `80`:
- If last-edited was reps, interpret as reps.
- Otherwise iPhone asks `kg` vs `reps`; watch defaults to weight and warns.

## Run

1. Build and run iOS app on device.
2. Start workout from Home.
3. Hold mic button on live screen and speak command.
3.1. Or enable `Always Listen` in Settings, choose a wake word, then say wake word + command.
Built-in wake words: `Lift`, `Whis`, `Logger`, `Ready` (with tolerant aliases for each).
4. Confirm toast message for recognized phrase + applied action.
5. On watch, use the big mic button and Done/Prev/Next controls.

## Architecture

- `WorkoutStore`: command application, workout state, undo stack.
- `SpeechRecognizerService`: push-to-talk lifecycle and permissions.
- `CommandParser`: regex/token parser (pure).
- `WatchSyncManager`: intents + snapshot sync.
- `CommandToastView`: reusable animated confirmation overlay.
## Future Notes (Natural Speech, Cost-Safe)

Planned direction for more natural command understanding while keeping costs bounded:

- Keep deterministic local command execution in `WorkoutStore` as source of truth.
- Keep local transcription/parser first pass.
- Add optional cloud fallback only for low-confidence/unrecognized transcripts:
  - text-only (not realtime audio streaming),
  - strict JSON schema output with fixed allowed intents,
  - hard usage limits (per workout/day) and budget cap auto-disable.
- Keep TTS local (no cloud TTS), per product decision.

### Fully Local Alternatives to Improve Natural Speech

- Improve local NLU pipeline:
  - multi-intent extraction from one utterance,
  - synonym graph + confidence scoring + disambiguation.
- Use a small on-device transcription model (e.g. Whisper.cpp/CoreML-based) instead of Apple Speech when needed.
- Keep wake-word + silence-commit UX for stable command boundaries.

This keeps the app voice-first and more flexible without introducing unbounded cloud costs.

