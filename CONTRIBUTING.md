# Contributing

Bug reports and pull requests are welcome. For a larger change, open an issue first, so we agree on the idea before you write the code.

## Build and test

You need a Mac with Apple silicon, macOS 15 or newer, and Xcode 27.1 or newer.

```sh
swift build
swift test
.build/debug/duorex          # run your build in a terminal pane
```

The tests that draw the device read Apple's iPhone Duo model from your Xcode. Without the model, they are skipped.

To see one frame without a window or a simulator:

```sh
.build/debug/duorex snapshot --pattern --hinge 130 --out duo.png
```

The [Development](README.md#development) section of the README says which type does what.

## Pull requests

- One change per pull request. One logical change per commit.
- A bug fix comes with a test that fails without the fix.
- Match the code around your change. Do not reformat or refactor what you do not need to touch.
- Comments say why, in plain words. The code says what.
- If the change is one a user sees, add a line to `CHANGELOG.md` under `## Unreleased`.

GitHub runs the tests on each pull request.

## Releases

The version is one line in `Sources/duorex/Release.swift`. A release is the tag `v` plus that version, and the installer builds the newest such tag.

1. Change the version in `Release.swift`. duorex follows [semantic versioning](https://semver.org).
2. In `CHANGELOG.md`, rename `## Unreleased` to `## ` plus the version.
3. Merge these two changes as a pull request.
4. On the main branch, run `scripts/release.sh --dry-run`. It checks the repository, runs the tests, and shows the release notes.
5. Run `scripts/release.sh`. It tags the commit, pushes the tag, and publishes the release on GitHub.

After step 5, `duorex update` installs the new version.
