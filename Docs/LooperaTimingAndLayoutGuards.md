# Loopera Timing And Layout Guards

These are regression-prone paths. Check them before changing looper timing,
video finalization, edit mode, or layout preset code.

## Master Loop Stop

- Free-mode master stop must call `AudioLoopEngine.finishRecording` and restart
  playback immediately from the captured audio buffers.
- Do not wait for `AVCaptureMovieFileOutput` finalization before marking the
  audio loop recorded. Video can attach later.
- Avoid copying the whole master recording buffer on the real-time stop path.
  Whole-buffer transfer in `AudioLoopEngine.finishRecording` is intentional.

## Slave Loop Sync

- Slave loops are audio-first and must be exact multiples of the master loop's
  sample length.
- Early spacebar presses schedule stop at the next master multiple.
- Late spacebar presses trim back to the previous master boundary.
- Both cases must pass the intended target duration into the audio engine. It is
  not enough to quantize only the UI duration after recording.
- `beginRecordingSyncedToMaster` and `masterBoundaryOffsetSeconds` are part of
  the sample-grid sync path. Do not replace them with date or UI phase math.

## Layout/Edit Controls

- The edit panel must not be inserted inline in the toolbar because that shrinks
  the stage canvas.
- The edit panel must not leave a hit-test layer over the toolbar after closing.
  Closing edit mode intentionally clears first responder state and rebuilds the
  toolbar identity.
- Layout preset updates must resolve old saved filenames as well as display
  names. Old presets may have hyphenated filenames that display with spaces.
