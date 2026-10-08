# vcamdebug-msd — build & install (RootHide Dopamine)

mediaserverd-side virtual-camera frame replacer for debugging applications. Injects into `mediaserverd`,
hooks every `BWNodeOutput` subclass that implements `-emitSampleBuffer:`, and
overwrites camera `CVPixelBuffer` content in place with frames decoded from a
local mp4. Target: iOS 15–16.x, arm64e, **RootHide** Dopamine jailbreak.

## Build (GitHub Actions)

1. Upload the **contents of this folder to the repo root** (so `Makefile`,
   `Tweak.xm`, the `.m/.h` files, `control`, `vcamplus-msd.plist`, and
   `.github/workflows/build.yml` are all at the top level — NOT nested in a
   subfolder, or Actions won't find the workflow and `make` won't find the Makefile).
2. Push to `main`, or Actions tab -> "Build VCamPlus MSD (roothide)" -> Run workflow.
3. macos-14 runner, ~5 min. If it fails on the Theos clone or SDK download,
   just re-run (transient network).
4. Download the **`vcamplus-msd-roothide-deb`** artifact (zip) -> unzip -> `.deb`.

Build config (already set):
- `Makefile`: `THEOS_PACKAGE_SCHEME = roothide` (required for RootHide; a
  `rootless` build installs to `/var/jb/...` and RootHide's patcher rejects it).
- Workflow uses **roothide/theos** (not stock theos) and builds with
  `THEOS_PACKAGE_SCHEME=roothide`.
- The roothide install-theos script's own SDK auto-download hits an
  api.github.com rate limit on shared runners and exits non-zero; it is wrapped
  in `|| true` and the SDK is fetched explicitly afterward. Do not "fix" that by
  removing `|| true`.

To confirm the output is a roothide package (not rootless): inside the `.deb`,
files are laid out as `Library/MobileSubstrate/DynamicLibraries/...` with **no
`/var/jb` prefix**, and `control` says `Architecture: iphoneos-arm64e`.

## Install

1. Transfer the `.deb` to the device; install with **Sileo** (RootHide ships
   ElleKit, which performs the mediaserverd injection via the plist filter).
2. **Restart mediaserverd** — a respring does NOT reload it. Reboot, or
   `killall mediaserverd` (auto-relaunches). The constructor only runs on
   mediaserverd start.

## Activate (real rootfs paths, NOT the jbroot)

Create both files in the device camera roll folder:
- `/var/mobile/Media/DCIM/vcam.mp4`         — source video
- `/var/mobile/Media/DCIM/vcam_msd_active`  — empty enable flag

Disable by deleting the flag (reverts within ~500 ms). The tweak `stat()`s these
literal paths; it does NOT use `jbroot()`.

## Source-video constraints

- Must be named exactly `vcam.mp4` (hardcoded). Container is read by content, so
  a `.mov` renamed to `vcam.mp4` decodes fine.
- **No rotation/orientation handling.** `AVAssetReader` decodes stored pixels and
  the tweak ignores the track `preferredTransform`, so clips carrying a rotation
  matrix (typical phone recordings) appear rotated. Normalize first (bake
  rotation into pixels, reset matrix):
  `ffmpeg -i in.mov -c:v libx264 -pix_fmt yuv420p -metadata:s:v:0 rotate=0 vcam.mp4`
- Aspect handling is a single fixed `CropSourceToCleanAperture` scale (no
  letterbox/offset controls). Match the source aspect to the consumer geometry.

## Verify (no host needed)

Read `/var/mobile/Media/DCIM/vcam_msd_stats.txt` (rewritten every 5 s):
- Injection OK: `installState=3`, `installSubclassHits>=1`, `emitHookEverFired=1`
  (the last requires opening a camera app once so BWNodeOutput loads).
- Replacing: after activation + camera open, `enabled=1`, `playerStarted=1`,
  `hitTotal`/`vtSuccess` climbing, `lastDst=` shows real WxH/format.
- If the stats file never appears after reboot + opening Camera -> ElleKit didn't
  inject. The shipped `vcamplus-msd.plist` filters on `Executables -> mediaserverd`
  only; if RootHide's TweakInject needs it, add a `Bundles` entry for
  `com.apple.mediaserverd` to the plist and rebuild.

## Notes

- Under heavy multi-geometry recording CPU can approach ~1 core; acceptable for
  preview, may stress the mediaserverd watchdog on weaker devices.
