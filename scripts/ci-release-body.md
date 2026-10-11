<!--
  The `ci-latest` release body, in ONE file, used by every publisher:

    * backend (Linux X64)   — .github/workflows/reusable/backend.yml
    * backend (macOS ARM64) — .github/workflows/reusable/backend.yml
    * backend (Windows X64) — .github/workflows/reusable/backend.yml
    * android-apk           — .github/workflows/ci.yml

  It used to be inline in the backend job only, and the android job was
  forced to run strictly after the whole backend matrix purely so that it
  would be the LAST writer — a GitHub Release row is last-writer-wins and
  softprops/action-gh-release@v2 takes no lock over the tag. That ordering
  requirement is what stopped android-apk from starting early.

  Sharing the file removes the requirement: all four publishers now send
  byte-identical text, so it no longer matters which one wins the create
  race, and android-apk can run alongside the backends.

  @@SHA@@ / @@RUN@@ are substituted by the publish step from the workflow
  context. `body_path:` is NOT expression-evaluated by the action, which is
  exactly why the placeholders are literal here rather than ${{ }}.  -->

Rolling release — binaries from the latest green `main` build.

- Commit: @@SHA@@
- Built: @@RUN@@

Asset names carry the binary name + zig target triple.
Linux/macOS ship bare binaries, e.g. `pabrik-x86_64-linux-gnu`,
`pabrik-desktop-aarch64-macos`, plus `pabrik-html-<triple>.tar.gz`
holding the web UI — `install.sh` extracts it next to the binaries so
a bare `pabrik` serves /app with no flags.
macOS also ships `Pabrik-aarch64-macos.zip` holding Pabrik.app
(pabrik-desktop + pabrik service inside, ad-hoc signed).
macOS setup (no sudo): extract the zip, move Pabrik.app to
~/Applications -- Spotlight/Launchpad find it as "Pabrik".
If Gatekeeper blocks the first launch, run
`xattr -dr com.apple.quarantine ~/Applications/Pabrik.app`.
Windows ships ONE self-contained .zip, e.g.
`pabrik-desktop-x86_64-windows-gnu.zip` -- it holds
pabrik-desktop.exe + pabrik.exe (the desktop auto-spawns
the service beside itself) plus every runtime DLL
(libcurl / sqlite3 / ssl / ... + WebView2Loader.dll)
plus html/ (the shipped UI, served via --static-dir;
always present -- the bundle gate fails the job otherwise)
plus Install-Pabrik.ps1 (the Windows setup script).
Extract the zip and run pabrik-desktop.exe; a bare .exe
alone cannot start (loader needs the DLLs beside it).
Windows setup (no admin): extract the zip, then run
`powershell -ExecutionPolicy Bypass -File Install-Pabrik.ps1`
from the extracted folder -- installs both exes + DLLs to
%LOCALAPPDATA%\pabrik\bin, html/ to
%LOCALAPPDATA%\pabrik\html, and adds a Start Menu shortcut
(Win key -> "Pabrik"). `-Uninstall` removes it again.
Install both binaries with
`sudo scripts/install-pabrik-desktop.sh` after downloading.
Android ships `Pabrik-android-debug.apk` -- the Kotlin/Compose
client from src/apps/android_mobile, minSdk 26 (Android 8.0),
signed with the auto-generated Android SDK debug key. It is
the DEBUG variant because no release keystore is committed and
none is configured, so a release-signed apk cannot be built
from this repo; `-debug` in the asset name and this sentence
are the disclosure. Play Protect will warn, and this apk
cannot later be upgraded by a properly-signed one without an
uninstall first (Android refuses an upgrade whose signing key
differs). It is a real client, not a stub -- the API host is
compiled in (BuildConfig.API_BASE_URL) and, with no
`-PpabrikBaseUrl` override, points at
https://agent.ginwa.site, the same host a release build would
use, so sign in with your pabrik account. The apk does NOT ship
or start a server: run pabrik somewhere, and this app talks to
it. Install with `adb install Pabrik-android-debug.apk` (device
connected, USB debugging on), or copy the file to the phone and
open it, allowing "install unknown apps" for whatever handles
the tap. To aim it at a pabrik on your own machine instead,
rebuild with `-PpabrikBaseUrl=http://10.0.2.2:<port>` -- that
address is the emulator's alias for the host's loopback, which
is how the app reaches a server bound to 127.0.0.1 -- or use
`adb reverse tcp:<port> tcp:<port>`. Either route is plain
HTTP, which only the debug variant allows: its network
security config permits cleartext to 10.0.2.2, localhost and
127.0.0.1 and refuses it everywhere else.
