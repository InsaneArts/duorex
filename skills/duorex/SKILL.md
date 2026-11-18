---
name: duorex
description: Builds an iOS app, runs it on an iPhone Duo simulator and uses it there - looks at the screen, taps, swipes, folds and rotates the device, and checks every posture - while the user watches the device in a Rex pane. Use when the user asks to run, try, test, check or show an app on iPhone Duo, "the Duo" or the foldable iPhone; after you change an iOS app that must work on iPhone Duo; or when the user mentions duorex.
---

# duorex

duorex shows an iPhone Duo simulator as a 3D device in a pane of Rex, and gives you shell commands to run an app on it and use it. The user watches: each touch you make shows on the device as an orange spot.

## Run the app

Run this in the folder of the Xcode project:

```sh
duorex run
```

It builds the project for the Duo simulator, starts the app, and opens a duorex pane beside yours if none is open. Its last line says how the device is: `running  ·  inner screen 2852x2006, hinge 180, held upright`.

- If the project has several schemes, add `--scheme Name`.
- If you built the app yourself, give it: `duorex run --app path/to/App.app`.
- If the build fails, the command prints the compiler's errors. Fix them and run it again.

The first run on a Mac creates the simulator and takes about 30 seconds more.

## Look

```sh
duorex screenshot
```

It prints the path of a PNG of the lit screen, upright. Read that file. Take a screenshot after each action: it is the only way to know what the app did.

`duorex screenshot --grid` draws a line at each tenth of the screen, with its number. Use it when you need the numbers for a tap.

## Touch

A point is two numbers from 0 to 1 on the upright screenshot: x runs right, y runs down.

```sh
duorex tap 0.46 0.57
duorex swipe 0.5 0.8 0.5 0.3     # a finger moves from the first point to the second
duorex home
duorex press power               # power, volume-up, volume-down, camera
```

## Fold and turn

```sh
duorex fold book                 # shut, book, open, or an angle from 0 to 180
duorex rotate clockwise          # upright, clockwise, upside-down, counterclockwise
```

A shut device shows the app on its small cover screen. From about half open, the app is on the inner screen. The app lays out again each time, so take a screenshot after a fold or a turn.

## Check every posture

```sh
duorex sweep --out sweep.png
```

It folds the device shut, to a book and open, held upright and turned, and saves one picture with all six. Read the picture to find a posture where the layout breaks. It puts the device back after.

## The usual order

1. `duorex run`
2. `duorex screenshot`, and read it. Is the change you made there?
3. Use the app: tap, swipe, take a screenshot, read it.
4. `duorex sweep --out sweep.png`, and read it. Fix what breaks in a posture, then go back to step 1.
5. Tell the user what you saw, and give the paths of the pictures.

## Limits

- You cannot type text into the app. Put test text in the app through its launch state or its code.
- The pane is the user's. Do not close it. If the user closed it, `duorex run` opens it again.
- Outside Rex there is no pane. The commands work the same.
