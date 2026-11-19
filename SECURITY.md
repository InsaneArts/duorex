# Security

## Report a vulnerability

Do not open a public issue for a security problem. Use **Report a vulnerability** on the [Security tab](https://github.com/InsaneArts/duorex/security) of this repository. Only the maintainer sees the report.

Say what the problem is, how to reproduce it, and which version you run (`duorex version`).

## Supported versions

Only the newest release gets fixes. Run `duorex update` to get it.

## What duorex does on your Mac

- It runs as you, with no extra rights. It never asks for a password.
- It controls the simulator through [simhost](https://github.com/InsaneArts/simhost). simhost loads Xcode's private simulator frameworks, and runs a helper inside the simulator that it builds with your Xcode and keeps in `~/Library/Caches/simhost`.
- The simulator's host is a process of duorex. It listens on a Unix socket in your temporary folder, which only your user can open. Any program that runs as you can.
- The installer and `duorex update` get the source of duorex and of simhost from GitHub, and build it on your Mac.
- Apart from that, duorex does not use the network.
