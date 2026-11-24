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

The keys the user has in the pane, the pictures and movies duorex makes for them, and what to do when a command fails are in [REFERENCE.md](REFERENCE.md). Read it when the user asks about the pane, a picture or a movie, or when a command fails.
