# Security

## Report a vulnerability

Do not open a public issue for a security problem. Use **Report a vulnerability** on the [Security tab](https://github.com/tornikegomareli/duorex/security) of this repository. Only the maintainer sees the report.

Say what the problem is, how to reproduce it, and which version you run (`duorex version`).

## Supported versions

Only the newest release gets fixes. Run `duorex update` to get it.

## What duorex does on your Mac

- It runs as you, with no extra rights. It never asks for a password.
- It starts [serve-sim](https://github.com/EvanBacon/serve-sim), which controls the simulator. If serve-sim is not installed, `npx` downloads version 0.1.49 from npm.
- serve-sim listens on `127.0.0.1` only, so other computers cannot reach it. Other programs on your Mac can.
- duorex talks only to that server and to Xcode's tools. It sends nothing to the internet.
- The installer and `duorex update` get the source from this repository and build it on your Mac.
