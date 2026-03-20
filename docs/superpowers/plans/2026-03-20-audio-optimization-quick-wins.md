# Audio Optimization Quick Wins Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce obvious audio overhead, cleanup bugs, and low-risk latency issues on Android and iOS before attempting any architecture rewrite.

**Architecture:** Keep the current public Flutter API and native plugin boundaries intact. Prioritize fixes that are local, measurable, and unlikely to break behavior: resource cleanup, session configuration, defensive guards, and removal of workaround delays. Defer bridge redesign and iOS engine topology changes until after quick wins are verified.

**Tech Stack:** Flutter plugin, Kotlin, C++, Swift, MethodChannel, FluidSynth, AVAudioEngine, AVAudioUnitSampler

---

## File Map

- Modify: `android/src/main/kotlin/com/melihhakanpektas/flutter_midi_pro/FlutterMidiProPlugin.kt`
- Modify: `android/src/main/cpp/native-lib.cpp`
- Modify: `ios/Classes/FlutterMidiProPlugin.swift`
- Optional docs update: `README.md`

## Chunk 1: Android Quick Wins

### Task 1: Remove load-time mute and artificial delay

**Files:**
- Modify: `android/src/main/kotlin/com/melihhakanpektas/flutter_midi_pro/FlutterMidiProPlugin.kt`

- [ ] **Step 1: Write a failing manual verification checklist**

Document expected behavior:
- Loading a soundfont does not mute device media volume.
- Loading returns as soon as native load finishes.
- Existing example app still loads and plays notes.

- [ ] **Step 2: Remove the workaround**

Change `loadSoundfont` flow to:
- Keep background loading on `Dispatchers.IO`.
- Remove `AudioManager.adjustStreamVolume(...ADJUST_MUTE...)`.
- Remove `delay(250)`.
- Remove `ADJUST_UNMUTE`.

- [ ] **Step 3: Run static verification**

Run:
```bash
rg -n "ADJUST_MUTE|ADJUST_UNMUTE|delay\\(250\\)|AudioManager" android/src/main/kotlin/com/melihhakanpektas/flutter_midi_pro/FlutterMidiProPlugin.kt
```
Expected:
- No `ADJUST_MUTE`
- No `ADJUST_UNMUTE`
- No `delay(250)`

- [ ] **Step 4: Run plugin analysis/build verification**

Run:
```bash
flutter analyze
```
Expected: no new errors from plugin changes

- [ ] **Step 5: Commit**

```bash
git add android/src/main/kotlin/com/melihhakanpektas/flutter_midi_pro/FlutterMidiProPlugin.kt
git commit -m "fix: remove android soundfont loading mute workaround"
```

### Task 2: Fix Android native resource cleanup

**Files:**
- Modify: `android/src/main/cpp/native-lib.cpp`

- [ ] **Step 1: Write the failing review checklist**

Document required cleanup invariants:
- `unloadSoundfont(sfId)` deletes driver, synth, and settings for that `sfId`.
- `dispose()` deletes and clears all native containers.
- Missing `sfId` should not crash on unload.

- [ ] **Step 2: Implement minimal cleanup fixes**

Update native code to:
- Guard `unloadSoundfont` with presence checks.
- Call `delete_fluid_settings(settings[sfId])` during unload.
- Erase `settings[sfId]` during unload.
- Call `settings.clear()` inside `dispose()`.

- [ ] **Step 3: Add defensive null/presence checks**

Before deleting driver/synth/settings:
- Verify the entry exists in each map.
- Avoid implicit `operator[]` insertions for invalid ids.

- [ ] **Step 4: Run focused verification**

Run:
```bash
rg -n "delete_fluid_settings|settings.clear|find\\(sfId\\)" android/src/main/cpp/native-lib.cpp
```
Expected:
- `delete_fluid_settings` appears in unload path
- `settings.clear()` appears in dispose path
- unload path contains guard checks

- [ ] **Step 5: Run plugin analysis/build verification**

Run:
```bash
flutter analyze
```
Expected: no new errors from plugin changes

- [ ] **Step 6: Commit**

```bash
git add android/src/main/cpp/native-lib.cpp
git commit -m "fix: clean up android native fluidsynth resources"
```

### Task 3: Add basic Android native state safety

**Files:**
- Modify: `android/src/main/cpp/native-lib.cpp`

- [ ] **Step 1: Write the failing review checklist**

Document concurrency risks to remove:
- Native maps are not accessed with unchecked invalid ids.
- Load/unload/play paths do not rely on accidental default map insertion.

- [ ] **Step 2: Implement the smallest safe guard layer**

Refactor native access to:
- Resolve map entries with `find`.
- Return early on invalid `sfId`.
- Keep behavior unchanged for valid `sfId`.

Do not add a full threading model yet.

- [ ] **Step 3: Run focused verification**

Run:
```bash
rg -n "\\[sfId\\]|find\\(sfId\\)|return;" android/src/main/cpp/native-lib.cpp
```
Expected:
- Fewer direct `map[sfId]` reads on hot paths
- Invalid ids return safely

- [ ] **Step 4: Run plugin analysis/build verification**

Run:
```bash
flutter analyze
```
Expected: no new errors from plugin changes

- [ ] **Step 5: Commit**

```bash
git add android/src/main/cpp/native-lib.cpp
git commit -m "refactor: guard android native synth lookups"
```

## Chunk 2: iOS Quick Wins

### Task 4: Configure AVAudioSession explicitly

**Files:**
- Modify: `ios/Classes/FlutterMidiProPlugin.swift`

- [ ] **Step 1: Write the failing review checklist**

Document expected session behavior:
- Playback category is set explicitly.
- Session is activated before engine use.
- Preferred buffer duration and sample rate are configured conservatively.
- Existing interruption handling remains intact.

- [ ] **Step 2: Implement minimal session setup**

Add a dedicated method, called from init or before first engine start, that sets:
- `AVAudioSession` category for playback use
- reasonable mode/default options
- `preferredSampleRate`
- `preferredIOBufferDuration`
- `setActive(true)`

Keep configuration conservative to avoid changing app mixing semantics unless the plugin already expects mixing.

- [ ] **Step 3: Add safe logging on session failure**

If session setup fails:
- log the error
- do not crash the plugin

- [ ] **Step 4: Run focused verification**

Run:
```bash
rg -n "setCategory|setActive|preferredIOBufferDuration|preferredSampleRate" ios/Classes/FlutterMidiProPlugin.swift
```
Expected:
- all four appear in the plugin

- [ ] **Step 5: Run plugin analysis/build verification**

Run:
```bash
flutter analyze
```
Expected: no new errors from plugin changes

- [ ] **Step 6: Commit**

```bash
git add ios/Classes/FlutterMidiProPlugin.swift
git commit -m "feat: configure ios audio session for playback"
```

### Task 5: Add iOS defensive guards and cleanup consistency

**Files:**
- Modify: `ios/Classes/FlutterMidiProPlugin.swift`

- [ ] **Step 1: Write the failing review checklist**

Document expected safety rules:
- Invalid `sfId` or channel does not crash.
- `dispose()` clears all native state consistently.
- `unloadSoundfont()` and `dispose()` clean up the same state buckets.

- [ ] **Step 2: Replace force unwraps on hot call paths**

For:
- `selectInstrument`
- `playNote`
- `stopNote`

Use guarded lookup and return `FlutterError` instead of crashing on invalid state.

- [ ] **Step 3: Align dispose cleanup**

Ensure `dispose()` clears:
- `audioEngines`
- `soundfontSamplers`
- `soundfontURLs`

- [ ] **Step 4: Run focused verification**

Run:
```bash
rg -n "soundfontURLs = \\[:\\]|guard let|FlutterError" ios/Classes/FlutterMidiProPlugin.swift
```
Expected:
- dispose clears `soundfontURLs`
- hot paths use guarded lookup

- [ ] **Step 5: Run plugin analysis/build verification**

Run:
```bash
flutter analyze
```
Expected: no new errors from plugin changes

- [ ] **Step 6: Commit**

```bash
git add ios/Classes/FlutterMidiProPlugin.swift
git commit -m "fix: harden ios plugin state handling"
```

## Chunk 3: Verification and Decision Gate

### Task 6: Verify quick wins before larger optimization

**Files:**
- Modify: `README.md` if behavior changes need documenting

- [ ] **Step 1: Run analysis**

Run:
```bash
flutter analyze
```
Expected: pass or only pre-existing non-related warnings

- [ ] **Step 2: Smoke test example app**

Run on available devices/simulators:
```bash
flutter run
```
Manual checks:
- load soundfont
- play note
- stop note
- stop all notes
- unload soundfont
- reload soundfont

- [ ] **Step 3: Record findings**

Capture:
- whether Android load is now faster/smoother without mute workaround
- whether iOS startup/playback is stable with explicit audio session config
- whether any regressions appear in example flow

- [ ] **Step 4: Decide whether to continue to medium-complexity work**

Only proceed to larger changes if quick wins are stable:
- Android mutex/thread model around native state
- Android batched MIDI/native scheduling path
- iOS single-engine or pooled-engine redesign
- Flutter API additions for batch event submission

- [ ] **Step 5: Commit docs if needed**

```bash
git add README.md
git commit -m "docs: note audio behavior and platform caveats"
```

## Deferred Work

Do not start these until quick wins are verified:
- Replace Flutter per-event `MethodChannel` calls with batched/native scheduling.
- Redesign iOS from `16` engines per soundfont to a lighter engine/sampler topology.
- Add device-adaptive latency tuning for FluidSynth.
- Add automated native-level performance benchmarks.

## Success Criteria

- Android no longer mutes or delays system audio during soundfont load.
- Android native resources are cleaned up correctly on unload/dispose.
- Invalid native ids fail safely instead of crashing or creating hidden state.
- iOS configures `AVAudioSession` explicitly and keeps interruption handling.
- iOS hot paths stop relying on force unwraps for runtime state.
- Public Flutter API remains unchanged.
