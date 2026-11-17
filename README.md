# duorex

An interactive 3D iPhone Duo in a Rex pane. The device is Apple's own model from Xcode, the
screens are the live simulator, and you fold it by dragging its frame.

duorex runs inside the pane as a terminal program. It draws the device in a click-through
window that sits over the pane and follows it. Rex keeps the pointer and the keyboard, so the
pane focuses, splits, and closes like any other pane.

## Requirements

- macOS 15 or later on Apple silicon
- Xcode 27.1 or later with an iOS 27.1 or later simulator runtime
- Node.js, for [serve-sim](https://github.com/EvanBacon/serve-sim)
- A terminal that reports the pointer in pixels (SGR mode 1016): Rex, Ghostty

## Install

```sh
swift build -c release
cp .build/release/duorex ~/.local/bin/
```

For a Rex action, copy `rex/duorex.lua` to `~/.config/rex/` and add this to `init.lua`:

```lua
require("duorex")
rex.bind("ctrl+p>i", "duorex")
```

## Use

Run `duorex` in a pane. The first run creates a simulator named "duorex Duo" and starts
serve-sim for it. That takes about 30 seconds. Later runs attach to the running server.

| Input | Effect |
|---|---|
| Click or drag on a screen | Touch |
| Scroll on a screen | Scroll |
| Drag the frame, or Option-drag | Fold |
| Drag the background | Tilt |
| `1` `2` `3` | Closed, book (130°), open |
| `[` `]` | Fold 10° less or more |
| `r` | Rotate a quarter turn |
| `h` | Home |
| `q` | Quit |

The device needs one pointer move over the pane the first time it runs in a terminal. That
move tells duorex where the pane is on screen.

Options:

- `--device <name|udid>` uses another iPhone Duo simulator.
- `--server <url>` attaches to a serve-sim that is already running, such as `http://127.0.0.1:3100`.
- `--finish Light` selects the light model. The default is `Dark`.

An agent can use the same simulator while you watch. serve-sim's own commands work on the
device: `serve-sim tap`, `serve-sim fold 130`, `serve-sim rotate`. The device in the pane
follows.

## How it works

- **Model.** `DuoScene` loads `V68.usdz` from the selected Xcode and renders it with RealityKit's
  `RealityRenderer`. The fold is the model's own animation, scrubbed by the hinge angle.
- **Screens.** serve-sim streams the active panel as H.264. `Sim` decodes it with VideoToolbox,
  and `ScreenFeed` copies each frame on the GPU into the texture on the device.
- **Input.** The terminal reports the pointer. `StageView` casts a ray from the pointer to the
  bent screen and sends the hit to serve-sim as a touch.
- **Docking.** A pointer report gives the pointer's position in the pane. The system gives its
  position on screen. The difference is the pane's origin. `Dock` keeps the window there and
  follows the terminal's window. In Rex, `RexHost` reads the layout to hide the device when its
  tab is not showing.

## Limits

- Keyboard text does not reach the simulator. With Xcode 27, serve-sim can type only through
  Device Hub.
- The fold and inner-screen touch use private Xcode interfaces through serve-sim. An Xcode
  update can break them. duorex pins the serve-sim release it was written against.
- `duorex snapshot --out file.png` renders one frame without a window. It exists to check the
  renderer.
