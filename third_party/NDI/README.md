# Vendored NDI SDK (iOS, arm64)

Only the pieces needed to link the NDI receiver into the daemon:

```
third_party/NDI/
├─ include/                   # NDI C API headers (Processing.NDI.*.h)
├─ lib/
│  └─ libndi_ios_arm64.a.gz   # arm64 DEVICE slice, gzipped (~31 MB)
└─ extract_sdk.sh             # regenerates the above from the .pkg
```

## Where it comes from
`Install_NDI_SDK_v6_Apple.pkg` (the macOS "NDI SDK for Apple" installer) bundles
the iOS/tvOS/visionOS libs. Its `libndi_ios.a` is a 268 MB universal archive
(x86_64 simulator + arm64 device). We keep **only the arm64 device slice**,
gzipped, because:
- GitHub rejects files > 100 MB (the raw slice is 133 MB; gzipped it's ~31 MB),
- we never build for the simulator.

The installer itself is **gitignored** — don't commit it.

## Regenerate
```bash
bash third_party/NDI/extract_sdk.sh
```

## CI / build
The build unzips the lib before linking:
```bash
gunzip -kf third_party/NDI/lib/libndi_ios_arm64.a.gz   # -> libndi_ios_arm64.a
```
The daemon links `-lndi_ios` against `third_party/NDI/lib` and includes
`third_party/NDI/include`. (The uncompressed `.a` is gitignored.)

## License
NDI SDK by NewTek/Vizrt, under its own SDK license (see the installer's
"NDI SDK License Agreement"). Vendored here for personal debugging use only.
