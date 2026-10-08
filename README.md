# vcamDebug-msd

mediaserverd-side virtual camera frame replacement for iOS Dopamine rootless for debugging operations so you can test your apps with a wide range of media without needing a huge camera setup hassle.

`vcamplus-msd` injects only into `mediaserverd` and swizzles
`-[BWNodeOutput emitSampleBuffer:]` on Apple's private CMCapture pipeline.
Every camera frame in the system passes through that selector before being
delivered to any consumer over XPC, so to ensure a smooth debugging operation across all kinds of app developing

## Architecture

| Class | Responsibility |
|---|---|
| `VCamCore` (singleton) | State holder; orchestrates per-frame replacement |
| `LocalVideoPlayer` | AVAssetReader-driven background decoder; loops `vcam.mp4` |
| `GPUImageProcessor` | VTPixelTransferSession-backed format/scale conversion + CVPixelBufferPool cache |
| `Tweak.xm` | Constructor that installs the three swizzles via MSHookMessageEx |

## Source video path

`/var/mobile/Media/DCIM/vcam.mp4`

DCIM is mediaserverd-accessible without RootHide jbroot path patching.
Drop a video at that path to enable.
Remove the file to disable. (Cached 200 ms so the file stat overhead is
negligible on the 1000+/sec emit hot path.)

## Filter

Injects into `mediaserverd` only. Does not touch SpringBoard, UI processes, or
WebContent.
