---
name: duorex
description: Builds an iOS app, runs it on an iPhone Duo simulator and uses it there - looks at the screen, taps, swipes, folds and rotates the device, and checks its postures - while the user watches the device in a Rex pane. Use when the user asks to run, try, test, check or show an app on iPhone Duo, "the Duo" or the foldable iPhone; after you change an iOS app that must work on iPhone Duo; or when the user mentions duorex.
---

# duorex

duorex shows an iPhone Duo simulator as a 3D device in a pane of Rex, and gives you shell commands to run an app on it and use it. The user watches: each touch you make shows on the device as an orange spot.

Every command ends with a line that says how the device is, such as `inner screen 2853x2007, hinge 180, held upright`. The lit screen, its size and the hinge come from the simulator. To check a fold, look at which screen is lit, and take a screenshot.

## Run the app

Run this in the folder of the Xcode project. The other commands work from any folder.

```sh
duorex run
```

It builds the project for the Duo simulator, starts the app, and opens a duorex pane beside yours if none is open.

- If the project has several schemes, add `--scheme Name`.
- If you built the app yourself, give it: `duorex run --app path/to/App.app`.
- If the build fails, the command prints the compiler's errors. Fix them and run it again.

The first run on a Mac creates and starts the simulator, which takes one to three minutes. Give the first command a time limit of at least five minutes, plus the time the build takes.

## Look

```sh
duorex screenshot                    # or: duorex screenshot --out /path/shot.png
```

The first line it prints is the path of a PNG of the lit screen, the way the user sees it. Read that file. Take a screenshot after each action: it is the only way to know what the app did.

`duorex screenshot --grid` draws a line at each tenth of the picture, with its number. Use it to find the numbers for a tap.

What is normal on a Duo screen:

- The clock and the status marks are in a column at one side, and the cover screen has a camera hole. The system keeps that space free, so an app's content is centred in what is left and can sit a little off the middle of the picture.
- On the inner screen, the fold runs through the middle of the picture's longer side: at x = 0.5 on a wide picture. A control that lies across that line is on the fold.

## Touch

A point is two numbers from 0 to 1 on the newest screenshot: x runs right, y runs down. After a fold or a turn, take a new screenshot before you tap.

```sh
duorex tap 0.62 0.35
duorex swipe 0.5 0.8 0.5 0.3     # a finger moves from the first point to the second
duorex home
duorex press power               # power, volume-up, volume-down, camera
duorex type "hello@example.com"  # into the field that has focus; tap the field first
```

`type` takes printable ASCII, as on a US keyboard. A line break in the text is the return key.

## Fold and turn

```sh
duorex fold book                 # closed (0), book (130), open (180), or an angle
duorex rotate clockwise          # upright, clockwise, upside-down, counterclockwise
```

A closed device shows the app on its small cover screen. From about half open, the app is on the inner screen. The app lays out again each time.

## Check the postures

```sh
duorex sweep
```

It saves one picture of six postures: closed, book and open, each held upright and turned clockwise. Its last line is the picture's path. Read the picture to find a posture where the layout breaks: content that is cut off, that overlaps, or that lies on the fold. The sweep puts the device back in the posture it had. For the two other holds, use `duorex rotate`.

## The usual order

1. `duorex run`
2. `duorex screenshot`, and read it. Is the change you made there?
3. Use the app: tap, swipe, take a screenshot, read it.
4. `duorex sweep`, and read it. Fix what breaks in a posture, then go back to step 1.
5. Tell the user what you saw, and give the paths of the pictures.

## Limits

- You cannot type text into the app. Put test text in the app through its launch state or its code.
- The pane is the user's. Do not close it. If the user closed it, `duorex run` opens it again.
- Outside Rex there is no pane. The commands work the same.
- Save pictures outside the project folder, or they end up in the user's repository.
