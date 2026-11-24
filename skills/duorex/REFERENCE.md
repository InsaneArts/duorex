# duorex reference

## The pane's keys

These are the user's, to tell them about. In the pane:

- Click or drag on the screen to touch it. Scroll to scroll. Option-drag on the screen pinches.
- Click a button on the frame to press it.
- Drag the background to turn the device. It comes back when let go.
- On iPhone Duo: drag the frame to fold. `1` `2` `3` choose closed, book and open. `[` and `]` fold 10 degrees less or more. `m` turns the fold sounds off or on.
- `r` turns the device a quarter turn clockwise. `h` goes home. `q` quits.
- `d` switches dark mode. `+` and `-` change the text size. `s` slows the animations. `w` sends a memory warning.
- `g` turns the glow around the device off or on. `?` shows the keys, a few at a time.

`duorex --device "iPhone 18 Pro"` in a pane shows that iPhone there. `duorex devices` lists the models.

## Pictures and movies

These make pictures for the user, not for checking the app. Each prints the path of what it made.

| Command | What it makes |
|---|---|
| `duorex sweep [--out sheet.png]` | The Duo in six postures, with the size the app got in each. About 20 seconds |
| `duorex record [--out movie.mp4] [--size 1920x1080]` | Runs as the pane, and films the device on a dark stage. `q` stops and saves. iPhone Duo only |
| `duorex strobe [--out poster.png] [--size 2560x1440]` | One picture of the Duo at seven fold angles |
| `duorex film [--out film.mp4] [--size 1920x1080]` | A ten-second movie of the Duo folding, with the app's screens on it |
| `duorex snapshot --device "iPhone 18 Pro" [--out iphone.png]` | A flat iPhone with a test pattern on its screen, with no simulator |

## When a command fails

- `the simulator sent no picture`: the simulator is still starting, or it stopped. Run the command again. A new simulator takes one to three minutes the first time.
- `no simulator or iPhone model is named ...`: run `duorex devices`, and use a name from it.
- `this iPhone does not fold` or `needs iPhone Duo`: `fold`, `sweep`, `strobe`, `film` and `record` work with the Duo only. Leave out `--device` to use it.
- The build fails: `duorex run` prints the compiler's errors. With several schemes, add `--scheme Name`.
- Typed text is missing: tap the field, take a screenshot to see the cursor in it, and type again.
- A tap lands in the wrong place: take a new screenshot. After a fold or a turn, the old one's points no longer match.
- Anything else: `duorex version` says the version, and `duorex update` installs the newest release.

## How it works

duorex reads the simulator's screens straight from its framebuffers, and sends input through simhost: one host process for each simulator, which duorex starts as `duorex host <udid>` when none runs. The host passes each client's input to the others, so the pane shows what you do. It stops ten minutes after its last client leaves.
