# Loopera Timing And Layout Guards

These are regression-prone paths. Check them before changing looper timing,
video finalization, edit mode, or layout preset code.

The known-good audio looping milestone is tagged in git as
`perfect-audio-looping-savepoint`. Return to that tag when comparing future
audio timing regressions.

## Master Loop Stop

- Free-mode master stop must call `AudioLoopEngine.finishRecording` and restart
  playback immediately from the captured audio buffers.
- Do not wait for `AVCaptureMovieFileOutput` finalization before marking the
  audio loop recorded. Video can attach later.
- Avoid copying the whole master recording buffer on the real-time stop path.
  Whole-buffer transfer in `AudioLoopEngine.finishRecording` is intentional.
- Audio captured from `AVCaptureAudioDataOutput` must be normalized to the
  looper engine sample rate before threshold, prebuffer, recording, and duration
  math. A 44.1 kHz input played through a 48 kHz output engine will sound sped up
  if the raw input frames are stored directly.

## Slave Loop Sync

- Slave loops are audio-first and must be exact multiples of the master loop's
  sample length.
- Early spacebar presses schedule stop at the next master multiple.
- Late spacebar presses trim back to the previous master boundary.
- Both cases must pass the intended target duration into the audio engine. It is
  not enough to quantize only the UI duration after recording.
- `beginRecordingSyncedToMaster` and `masterBoundaryOffsetSeconds` are part of
  the sample-grid sync path. Do not replace them with date or UI phase math.
- Do not poll the slave recording duration to decide when an early spacebar
  stop is done. Early slave stops must set a pending target duration and close
  from the master boundary crossing in `tick()`.
- New slave playback should be armed by `AudioLoopEngine.finishRecording` while
  the engine lock is held. A separate restart call after finalizing can create
  a render-cycle gap or read a later master phase.

## Loop Video Sync

- Loop videos are visual followers of the audio loop. The preferred video start
  offset is `recorded video duration - finalized audio loop duration - end trim`.
- Wall-clock offsets such as `pendingStartDate - captureStartDate` are fallback
  only. They can be wrong by seconds when a slave is armed before the next master
  boundary or another recording changes controller state before video finalizes.
- Captured loop video zoom should match the saved live preview zoom. Do not
  attenuate the loop zoom relative to the live preview unless the UI exposes that
  as a separate user setting.
- Camera capture and app-window capture are separate video source paths. Keep
  app-window recording video-only and attach the resulting file through the same
  finished-video slot finalization path; do not alter the audio engine for a new
  visual source.

## Layout/Edit Controls

- The edit panel must not be inserted inline in the toolbar because that shrinks
  the stage canvas.
- The edit panel must not leave a hit-test layer over the toolbar after closing.
  Closing edit mode intentionally clears first responder state and rebuilds the
  toolbar identity.
- Layout preset updates must resolve old saved filenames as well as display
  names. Old presets may have hyphenated filenames that display with spaces.
- Save and Update must write the current edit values directly. Do not close edit
  mode as part of the same button action before writing the preset, because that
  rebuilds toolbar/edit state while the click is still being handled.
