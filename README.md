<h1 align="center">duorex</h1>

<h3 align="center">A real iPhone Duo in your terminal pane.</h3>

duorex puts a 3D iPhone Duo in a [Rex](https://www.superlogical.com/rex) pane. The device is Apple's own model from Xcode, and its screens are the live simulator. You fold it with your pointer, and your agent can use the same device while you watch.

## Fold it like the real thing

Drag the frame and the device folds under your pointer. The simulator's hinge follows, so your app lays out again as the angle changes. Let go and it stays at that angle. Close to shut or to flat, it finishes the move.

`1`, `2` and `3` go to closed, book and open. `[` and `]` move the hinge 10 degrees.

## Touch what you see

Click, drag and scroll on either screen. The touch lands where you point, on a flat screen and on a bent one. `r` turns the device a quarter turn, and `h` swipes home.

Drag the background to tilt the device. It springs back when you let go.

## It stays in its pane

duorex runs in the pane as a terminal program and draws the device in a window over it. Rex keeps the pointer and the keyboard, so the pane focuses, splits and closes like any other.

Move the Rex window or change the layout and the device follows. Switch to another tab and it hides.

## Your agent uses the same device

duorex runs the simulator through [serve-sim](https://github.com/EvanBacon/serve-sim), so an agent in the next pane can drive it from the shell while you watch:

```sh
npx serve-sim tap 0.5 0.4    # a point on the screen, from 0 to 1
npx serve-sim fold 130
```

When the agent folds the device, the one in your pane folds too.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/tornikegomareli/duorex/main/install.sh | sh
```

The installer builds duorex from source and puts it in `~/.local/bin`.

Requirements:

- A Mac with Apple silicon, on macOS 15 or newer
- Xcode 27.1 or newer, with an iOS 27.1 or newer simulator runtime
- Node.js, for serve-sim
- Rex, or another terminal that reports the pointer in pixels, such as Ghostty

To open the device with a key in Rex, load the action from `~/.config/rex/init.lua`. The installer puts it in `~/.config/rex/duorex.lua`:

```lua
require("duorex")
rex.bind("ctrl+p>i", "duorex")
```

To update:

```sh
duorex update
```

## Remove

```sh
rm -f ~/.local/bin/duorex ~/.config/rex/duorex.lua
rm -rf ~/.local/share/duorex
defaults delete duorex 2>/dev/null   # the saved pane position
```

Delete the two lines from `~/.config/rex/init.lua` if you added them. serve-sim keeps running after duorex quits. To stop it and delete the simulator:

```sh
npx serve-sim --kill
xcrun simctl delete "duorex Duo"
```

## Using it

Run `duorex` in a pane. The first run creates a simulator named "duorex Duo" and starts serve-sim for it, which takes about 30 seconds. Later runs attach to the running server.

- Click or drag on a screen to touch it. Scroll to scroll.
- Drag the frame to fold. Option-drag folds from anywhere.
- Drag the background to tilt.
- `1` `2` `3` choose closed, book and open. `[` and `]` fold 10 degrees less or more.
- `r` rotates, `h` goes home, `q` quits.

The first time duorex runs in a terminal, move the pointer over the pane once. That tells duorex where the pane is on screen.

Options:

- `--device <name|udid>` uses another iPhone Duo simulator.
- `--server <url>` attaches to a serve-sim that is already running, such as `http://127.0.0.1:3100`.
- `--finish Light` shows the light model. The default is `Dark`.

## Limits

- Typing does not reach the simulator. With Xcode 27, serve-sim can type only through Device Hub.
- Folding and touches on the inner screen use private Xcode interfaces through serve-sim, so an Xcode update can break them. duorex pins the serve-sim release it was written against.
- Outside Rex, the device does not hide when you switch tabs, because other terminals do not report their layout.

## Development

```sh
swift build
swift test
.build/debug/duorex snapshot --pattern --hinge 130 --out duo.png   # one frame, no window
```

The device is `DuoScene`, drawn into `Frame`s by `StageView`. `DeviceMotion` holds its pose and turns the pointer into touches, tilts and folds. `Sim` and `ScreenFeed` bring the simulator's screen to it, in the wire format `SimWire` knows, and `PoseSync` decides whether the device or the simulator moved first. `Pane` reads the terminal through `TerminalInput`, and `Dock` keeps the window where `PaneLocator` says the pane is.

## License

[MIT License](LICENSE).
