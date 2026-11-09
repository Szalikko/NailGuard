<p align="center"><img src="Assets/AppIcon.png" width="88" alt="NailGuard HRT icon"></p>

# NailGuard HRT

NailGuard HRT is a macOS menu bar app that uses your camera to notice fingers near your mouth. It can play a sound and show an overlay to help you catch a nail-biting habit and practise a different response with Habit Reversal Training (HRT).

**Requires Apple Silicon and macOS 14 or later.** [Download NailGuard HRT 1.8.2](https://github.com/Szalikko/NailGuard/releases/tag/v1.8.2)

![NailGuard HRT 1.8.2 Monitoring window](docs/screenshot.png)

## Get started

1. Download `NailGuard-HRT-1.8.2-macOS-arm64.zip` from Releases, unzip it and move `NailGuard HRT.app` to Applications.
2. Open the app, click **Start** in **Monitoring** and allow camera access.
3. Use the live preview to tune detection. Adjust the sound, overlay, repeat interval and camera processing to suit your setup.

The downloadable app is signed ad hoc and has no Apple notarization. The menu bar menu contains **Open NailGuard HRT** and **Quit**.

## HRT Practice

1. Open **HRT Practice**, enable **HRT support** and choose a response that feels comfortable, such as relaxed fists or palms resting on your thighs.
2. Click **Rehearse** to try the overlay without the camera. Press **Control + Option + H** when you notice an urge yourself.
3. When detection offers a session, click **Start practice** to begin the countdown. You can dock the timer or set it to dock automatically. The docked position can follow the main overlay or be set separately.
4. At the end, an optional sound and check-in let you note whether you practised and how the urge changed. Check-ins can be turned off and do not delay new alerts.

HRT is optional. With repeat alerts enabled, a pending camera invitation can grow and get louder while your fingers stay near your mouth. Repeats stop when you move your hand away or start the HRT timer. For ordinary alerts, the overlay stays visible for the configured duration after you move your hand away.

## Statistics and privacy

- **Statistics** shows detections and HRT practice records in the selected date range. Camera detections indicate proximity to the mouth. Practice and urge changes are self-reported.
- Camera analysis runs on your Mac. NailGuard records no video and uploads no camera data. Event snapshots are stored locally and can be switched off under **Monitoring → More → History & privacy**.
- Settings and history are stored locally. Detection statistics, snapshots and HRT practice history can be managed separately.

## Build from source

With Xcode Command Line Tools installed, run the following from the **1.8.2 source tree**.

```sh
zsh build.command
```

The script builds `NailGuard HRT.app` for Apple Silicon, signs it locally and runs its self-tests.

100% Vibecoded
