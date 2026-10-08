# VCamControl — standalone controller app

A plain jailbreak app (`com.vcamplus.control`, installs to `/Applications` as
**VCam Control**) for the `vcamplus-msd` tweak. It does **not** inject into any
process. It only:

- lists `.mp4` / `.mov` / `.m4v` files in `/var/mobile/Media/DCIM`,
- writes the chosen clip to the shared config plist
  `/var/mobile/Media/DCIM/vcam_msd.plist` (`{"source": "<path>"}`),
- posts the Darwin notifications the tweak listens for, and
- reads back `vcam_msd_stats.txt` to show live `enabled` / `playerStarted`.

## Contract with the tweak (keep in sync)

| | value |
|---|---|
| Config plist | `/var/mobile/Media/DCIM/vcam_msd.plist`, key `source` |
| Enable  | Darwin note `com.vcamplus.msd.enable` |
| Disable | Darwin note `com.vcamplus.msd.disable` |
| Toggle  | Darwin note `com.vcamplus.msd.toggle` |
| Reload source | Darwin note `com.vcamplus.msd.reload` |

These must match the constants in `../VCamCore.m`.

## Why the entitlements

A normal iOS app sandbox cannot read `/var/mobile/Media/DCIM`. `entitlements.plist`
marks the app `platform-application` / no-container so it runs unsandboxed (like
any jailbreak utility) and can list clips and write the config plist. If a clip
select ever fails with a write error, the entitlements didn't take — confirm the
`.deb` signed with `-Sentitlements.plist`.

## Build

Needs roothide Theos with the iOS SDK already present (same setup as the tweak):

```bash
cd VCamControl
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

Output `.deb` lands in `VCamControl/packages/`. Install with Sileo. No
`mediaserverd` restart needed — this is just an app. Launch **VCam Control** from
the home screen.

> The tweak must already be installed and `mediaserverd` restarted, and a camera
> app opened once, before `enabled`/`playerStarted` in the status panel read 1.
