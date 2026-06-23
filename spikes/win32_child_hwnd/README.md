# Win32 child HWND probe

Status: candidate-only, not verified on Windows yet.

This spike adds an opt-in native child `HWND` probe to the Windows example
runner. It is meant to collect small, concrete evidence before asking Flutter
maintainers for deeper review. It is not a public API proposal, not a Flutter
engine design, and not a production plugin feature.

The probe is compiled only when `DESKTOP_UPDATER_WIN32_CHILD_HWND_PROBE` is
enabled. By default the example runner is unchanged.

## Run

From Windows PowerShell:

```powershell
cd example
$env:DESKTOP_UPDATER_WIN32_CHILD_HWND_PROBE = "1"
flutter run -d windows
```

From `cmd.exe`:

```bat
cd example
set DESKTOP_UPDATER_WIN32_CHILD_HWND_PROBE=1
flutter run -d windows
```

If CMake has already configured the build with the flag disabled, delete
`example/build/windows` and run the command again.

## Evidence to collect

- Screenshot or short screen recording showing the native edit control inside
  the Flutter Windows runner.
- `%TEMP%\flutter_child_hwnd_probe.log`.
- Resize evidence: resize the window and confirm `resize` lines appear in the
  log with changing client bounds.
- Focus evidence: click into the native edit control, type a few keys, click
  back into Flutter UI, and confirm `child-focus`, `child-keydown`, and
  `child-blur` lines appear.
- Dispose evidence: close the app and confirm `dispose-start`,
  `child-destroy`, `child-nc-destroy`, and `dispose-complete` lines appear.

## What this does not prove

- Framework `PlatformView` API shape.
- Flutter engine/embedder ownership, lifetime, or compositor contract.
- Z-order, clipping, transforms, overlays, DPI, IME, UI Automation,
  accessibility, multiple native views, or production WebView behavior.
- Linux `GtkWidget` behavior.

## Decision after the run

If the probe works, use the evidence only as a conversation starter: it shows
that a minimal child-window lifecycle can be observed in a Flutter Windows
runner. If the direction is still unclear after this small run, pause and ask
maintainers before creating broader design docs or implementation work.
