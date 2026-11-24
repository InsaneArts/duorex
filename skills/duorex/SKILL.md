---
name: duorex
description: Runs an iOS app on an iPhone simulator and uses it as a person does - screenshots, taps, swipes, typing, hardware buttons, turns, and folds on iPhone Duo - while the user watches the device in a Rex pane. Use it, rather than simctl or Simulator.app, whenever you build, run, test or check an iOS app; after any change to an iOS app that a person could see; and when the user mentions duorex, iPhone Duo or the foldable iPhone.
---

# duorex

duorex runs an iPhone simulator in a pane of Rex: iPhone Duo as a 3D device that folds, any other iPhone flat. Shell commands run your app on it and use it. The user watches: each touch you make shows on the device as an orange mark, and the line under the device names what you did.

Every command ends with a line that says how the device is: `inner screen 2853x2007, hinge 180, held upright` on the Duo, `screen 1206x2622, held upright` on another iPhone. Read it after each command.

## The loop

Run these in order. Each step is done when its check holds.

1. **Run.** In the folder of the Xcode project: `duorex run`. Done when it prints `running`. If the build fails, it prints the compiler's errors: fix them and run it again.
2. **Look.** `duorex screenshot`, then read the PNG whose path it prints first. Done when you have seen your change on the screen, or seen that it is missing.
3. **Use.** Tap, swipe, type and press, as the user would, with a screenshot after each action. Done when every path you changed has been walked and seen.
4. **Postures.** On iPhone Duo, `duorex sweep`, then read the picture. Done when no posture cuts off, overlaps or puts a control on the fold. Fix what breaks and go back to step 1.
5. **Report.** Tell the user what you saw, with the paths of the pictures.

The first run on a Mac makes and starts the simulator: one to three minutes. Give it a time limit of at least five minutes, plus the build.

## Which iPhone

Without `--device`, duorex uses iPhone Duo. For another iPhone, add the same `--device` to every command:

```sh
duorex devices                              # the iPhones duorex shows, and their simulators
duorex run --device "iPhone 18 Pro"         # a model from that list
duorex screenshot --device "iPhone 18 Pro"
```

A model's simulator is made on first use. A simulator's own name or UDID works too. Use the iPhone the user names. Only the Duo folds: `fold` and `sweep` need it.

## Commands

| Command | What it does |
|---|---|
| `duorex run [--scheme Name] [--app App.app]` | Builds the project here, starts the app, and opens the pane beside yours |
| `duorex screenshot [--out shot.png] [--grid] [--full]` | The screen as the user sees it, upright. `--grid` numbers each tenth |
| `duorex tap X Y` | One tap. X and Y run from 0 to 1 on the newest screenshot, from the top left |
| `duorex swipe X1 Y1 X2 Y2 [--seconds 0.25]` | A finger from the first point to the second |
| `duorex type "text"` | Types into the field that has focus. Tap the field first |
| `duorex home` | Goes home, with the swipe up from the bottom edge |
| `duorex press power` | Also `volume-up`, `volume-down`, `action`, and `camera` on the Duo |
| `duorex rotate clockwise` | Also `upright`, `upside-down`, `counterclockwise` |
| `duorex fold book` | The Duo's hinge: `closed`, `book`, `open`, or an angle from 0 to 180 |
| `duorex sweep [--out sheet.png]` | One picture of the Duo closed, as a book and open, upright and turned |
| `duorex open` | Opens the pane only |

After a fold or a turn, take a new screenshot before you tap: the points move with the interface.

`type` takes printable ASCII on a US keyboard. A line break is the return key. It returns once the app has taken every key.

## What the screen shows

- iPhone Duo: the clock and status marks stand in a column at one side, and the cover screen has a camera hole. The system keeps that space free, so content can sit a little off the middle. Closed, the app is on the small cover screen. From about half open, it is on the inner screen, where the fold runs across the middle of the longer side: x = 0.5 on a wide picture.
- Other iPhones: the Dynamic Island is in the screenshot, as the simulator draws it.
- An app lays out again after each fold and each turn.

## The pane

- The pane is the user's. Leave it open. If it is gone, `duorex run` or `duorex open` brings it back.
- Outside Rex there is no pane. Every command works the same.
- Pictures go to a temporary folder unless you give `--out`. Keep them out of the project folder.

The keys the user has in the pane, the pictures and movies duorex makes for them, and what to do when a command fails are under **Reference**, below. Read it when the user asks about the pane, a picture or a movie, or when a command fails.

## Reference

### The pane's keys

These are the user's, to tell them about. In the pane:

- Click or drag on the screen to touch it. Scroll to scroll. Option-drag on the screen pinches.
- Click a button on the frame to press it.
- Drag the background to turn the device. It comes back when let go.
- On iPhone Duo: drag the frame to fold. `1` `2` `3` choose closed, book and open. `[` and `]` fold 10 degrees less or more. `m` turns the fold sounds off or on.
- `r` turns the device a quarter turn clockwise. `h` goes home. `q` quits.
- `d` switches dark mode. `+` and `-` change the text size. `s` slows the animations. `w` sends a memory warning.
- `g` turns the glow around the device off or on. `?` shows the keys, a few at a time.

`duorex --device "iPhone 18 Pro"` in a pane shows that iPhone there. `duorex devices` lists the models.

### Pictures and movies

These make pictures for the user, not for checking the app. Each prints the path of what it made.

| Command | What it makes |
|---|---|
| `duorex sweep [--out sheet.png]` | The Duo in six postures, with the size the app got in each. About 20 seconds |
| `duorex record [--out movie.mp4] [--size 1920x1080]` | Runs as the pane, and films the device on a dark stage. `q` stops and saves. iPhone Duo only |
| `duorex strobe [--out poster.png] [--size 2560x1440]` | One picture of the Duo at seven fold angles |
| `duorex film [--out film.mp4] [--size 1920x1080]` | A ten-second movie of the Duo folding, with the app's screens on it |
| `duorex snapshot --device "iPhone 18 Pro" [--out iphone.png]` | A flat iPhone with a test pattern on its screen, with no simulator |

### When a command fails

- `the simulator sent no picture`: the simulator is still starting, or it stopped. Run the command again. A new simulator takes one to three minutes the first time.
- `no simulator or iPhone model is named ...`: run `duorex devices`, and use a name from it.
- `this iPhone does not fold` or `needs iPhone Duo`: `fold`, `sweep`, `strobe`, `film` and `record` work with the Duo only. Leave out `--device` to use it.
- The build fails: `duorex run` prints the compiler's errors. With several schemes, add `--scheme Name`.
- Typed text is missing: tap the field, take a screenshot to see the cursor in it, and type again.
- A tap lands in the wrong place: take a new screenshot. After a fold or a turn, the old one's points no longer match.
- Anything else: `duorex version` says the version, and `duorex update` installs the newest release.

### How it works

duorex reads the simulator's screens straight from its framebuffers, and sends input through simhost: one host process for each simulator, which duorex starts as `duorex host <udid>` when none runs. The host passes each client's input to the others, so the pane shows what you do. It stops ten minutes after its last client leaves.
