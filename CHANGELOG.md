# Changelog

Each release of duorex, newest first. Changes that are not in a release yet are under `## Unreleased`.

## Unreleased

**Every iPhone**
- duorex shows any iPhone. The Duo stays in 3D. Every other iPhone is drawn flat, in the chrome Simulator.app uses, with its live screen, its side buttons and the agent's marks.
- `duorex devices` lists the current iPhones. `--device "iPhone 18 Pro"` shows one, and makes its simulator the first time.
- `duorex press action` presses the Action button.
- `duorex snapshot --device "iPhone 18 Pro"` draws a flat iPhone with a test pattern on its screen.

## 0.2.0

duorex runs the simulator through [simhost](https://github.com/InsaneArts/simhost) instead of serve-sim, and no longer needs Node.js.

**The simulator**
- A touch shows on the screen about three times sooner: 5.6 ms from the touch to the frame that shows it, where serve-sim took 16.7 ms.
- The screens come straight from the simulator's framebuffers, at full resolution, with no video in between.
- duorex knows the hinge angle from the start, to the degree. With Xcode 27.2, 0.1.0 showed `hinge unknown` until something folded the device.

**For an agent**
- `duorex type` types into the app, in the field that has focus.
- An agent's swipe draws its trail while the finger moves, not after it.

**Removed**
- `--server`. There is no server to attach to.

**From 0.1.0**
- The serve-sim that 0.1.0 started can still run. To stop it: `npx --yes serve-sim@0.1.49 --kill "duorex Duo"`.

## 0.1.0

The first release.

**The device**
- Apple's 3D iPhone Duo model from Xcode, with the live simulator on both screens, in a window that stays on its Rex pane.
- Fold it with the pointer or with `1`, `2`, `3`, `[` and `]`. The simulator's hinge follows.
- Touch, scroll and pinch on either screen. Option-drag on a screen is a pinch.
- Turn the device all the way round with a drag on the background.
- Press the power, volume and camera control buttons on the frame.
- A sound when the device shuts and when it opens flat, and a glow around the device in the colours of the app.

**The simulator's settings**
- `d` for dark mode, `+` and `-` for the text size, `s` for slow animations, `w` for a memory warning.

**Pictures**
- `duorex sweep`: six postures in one picture.
- `duorex record`: a movie of the device alone on a dark stage.
- `duorex strobe`: one picture of the device at seven fold angles.
- `duorex film`: a ten-second movie with no hand on the device.

**For an agent**
- `duorex run` builds an Xcode project, starts the app on the Duo and opens the pane.
- `duorex screenshot`, `tap`, `swipe`, `home`, `fold`, `rotate` and `press`.
- The touches of an agent show on the device, and the line under it says what the agent does.
- A skill named `duorex` for Claude Code, Codex and pi.

**Install and update**
- `install.sh` builds from source. `duorex update` gets the newest release.
