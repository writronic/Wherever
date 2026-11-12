# Building and contributing

Build Wherever from source, check your change and send it from a fork.

## Requirements

- macOS 13 Ventura or later runs the app. The two test bundles deploy at macOS 14, so run the tests on macOS 14 or later.
- Xcode 27. Release builds use Xcode 27.0.
- Rust 1.91 or later, because the engine uses the 2024 edition and let chains, and the locked crates need 1.91. Add both Apple targets with [rustup](https://rustup.rs): `rustup target add aarch64-apple-darwin x86_64-apple-darwin`.
- A network connection. Xcode fetches [Sparkle](https://sparkle-project.org) 2.10.1, and Cargo fetches the crates pinned in `Engine/Cargo.lock`.
- Optional: the system Ruby with the `xcodeproj` gem, for `scripts/check_project.rb`.
- For release builds only: npm `create-dmg` 8.1.0, installed with `npm install --global create-dmg@8.1.0 --allow-scripts=fs-xattr,macos-alias`.

## Build the engine and the app

The app links the Rust engine, so build the engine first. Run this from the repository root, with Cargo's output outside the source tree:

```sh
CARGO_TARGET_DIR="$HOME/.cache/wherever-cargo" /bin/sh scripts/build-engine.sh
```

The script stops if `CARGO_TARGET_DIR` is unset. It builds `wherever-core` for both Apple targets at a 13.0 deployment target, joins them into one universal library, generates the Swift bindings and packages `WhereverKit/Engine/WhereverCore.xcframework`. Git tracks the generated Swift and ignores the xcframework. Run the script again after every change under `Engine/`.

1. Open `Wherever.xcodeproj`.
2. Select the `Wherever` scheme.
3. Press ⌘R.

The checked-in project signs with Writronic's team. Set your own under Signing & Capabilities, and keep that change out of your pull request. Without Full Disk Access only the welcome window opens, and each signing identity needs its own Full Disk Access switch. [Getting started](../docs/getting-started.md) walks through the welcome.

## Run the tests

Run the engine tests from `Engine/`:

```sh
MACOSX_DEPLOYMENT_TARGET=13.0 CARGO_TARGET_DIR="$HOME/.cache/wherever-cargo" cargo test
cargo fmt --check
cargo clippy --all-targets -- -D warnings
```

Tests marked `#[ignore]` read a disk that `WHEREVER_PROBE_ROOT` names, so `cargo test` skips them.

In Xcode, press ⌘U. The shared `Wherever` scheme runs both `WhereverKitTests` and `WhereverTests`. Swift treats warnings as errors in every target, so fix each warning before you push.

Some `WhereverTests` suites read the accessibility tree. SwiftUI builds that tree only while an accessibility client talks to the app, so those suites fail on a Mac with none running. The tests use small temporary folders and fakes, so they do not crawl your disk or write your data folder.

`/usr/bin/ruby scripts/check_project.rb` checks the project's targets, languages and settings and prints `check_project: OK`. It expects the checked-in team, so run it with your own team change undone.

## Find the right code

- `Engine/` holds the Rust crate `wherever-core`: the crawl, the index, live updates, queries and ranking. It also holds `wherever-cli` and `uniffi-bindgen-swift`.
- `WhereverKit/` holds the generated bindings and the engine xcframework. It is the only code that names the engine module.
- `Packages/WhereverInterface/` is a local package with no dependencies: protocols, `Sendable` structs and `WhereverError`.
- `WhereverHelper/` is the small login-item app that shows the menu bar icon and holds the launcher shortcut.
- `WhereverShared/` holds the code that both apps compile.
- `Wherever/` holds the views and the app. Only `WhereverApp.swift` imports `WhereverKit` and Sparkle.
- Code carries no comment lines; explain the why in the commit body. Localization notes and lines a tool reads (shebang, swift-tools-version, lint directives) stay.

The Swift folders are synchronized with the project, so a new Swift file there needs no edit to `project.pbxproj`.

The app runs down to macOS 13. Put every `#available` gate in `Wherever/Views/Shared/Availability.swift`. Use `ObservableObject` and `@Published`, because `@Observable` needs macOS 14.

## Add or change a string

Every interface string ships in 11 languages: en, tr, de, fr, es, ru, nl, ja, zh-Hans, ar and pl. A view writes `Text("English sentence", tableName: "Table")`. The English sentence is the key. Add it to `Wherever/Resources/l10n/en.lproj/Table.strings` with a value equal to the key, then add the same key with its translation to the same file in the other ten `.lproj` folders. Plural strings live in `Results.stringsdict`.

## Send a change

1. Search the [issues](https://github.com/writronic/Wherever/issues) for related work. Open an issue before a large change.
2. Fork the repository and clone your fork.
3. Create a branch from `main`.
4. Build and test, then commit and push the branch to your fork.
5. Open a pull request against `main`. Keep one change in each pull request, and rebase when `main` moves.

Write commit subjects in the imperative, in sentence case, under 72 characters, for example `Fix crash on empty query`. Say why in the body, and say what you ran.

## Build a release

Release builds are for maintainers. `scripts/build.sh --dry-run` runs only the preflight checks. It needs the `xcodeproj` gem and `create-dmg` 8.1.0 (see Requirements). A real run needs a Developer ID identity and a notary profile, and it uploads only to Apple's notary service, never to GitHub. A fork that ships builds needs its own Sparkle key pair and feed URL in `Config/Wherever-Info.plist`.

## Report a security issue

Send a vulnerability report through the private route in [SECURITY.md](../SECURITY.md). Use the issue tracker for ordinary bugs. Everyone who takes part follows [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md).

## Related

- [README](../README.md)
- [Getting started](../docs/getting-started.md)
- [License](../LICENSE)
