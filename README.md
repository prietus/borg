# BorgMac

A native macOS client for [Borg](https://www.borgbackup.org/) backup repositories. SwiftUI, menu bar app, Touch ID, launchd scheduling, and first-class panels for [BorgBase](https://www.borgbase.com/) and self-hosted [BorgBox](https://github.com/prietus/borgbox) servers.

BorgMac does not reimplement the Borg protocol. It drives the `borg` command line tool as a subprocess, so anything Borg can do with a repository, BorgMac can too, and your repositories stay fully usable from the terminal or any other client.

## Install

### Homebrew (recommended)

```sh
brew install --cask prietus/tap/borgmac
```

This installs `BorgMac.app` into `/Applications` and pulls in the `borgbackup` formula. Upgrade with `brew upgrade --cask borgmac`.

### Manual

Download `BorgMac-<version>.zip` from the [Releases](https://github.com/prietus/borg/releases) page, unzip, and drag `BorgMac.app` to `/Applications`. Builds are signed with a Developer ID and notarized by Apple.

You also need the `borg` binary. BorgMac looks for it in `/opt/homebrew/bin` and `/usr/local/bin`:

```sh
brew install borgbackup
```

### Requirements

- macOS 14 Sonoma or newer (Apple silicon and Intel).
- Borg 1.x on the Mac.

## Features

**Repositories**

- Local, SSH, BorgBase and BorgBox repositories side by side in one sidebar.
- Wizards to create a new repository on BorgBase (EU or US), on a BorgBox server, or on local disk / any SSH host, with a choice of encryption mode.
- Passphrases live in the macOS Keychain and are unlocked with Touch ID. Scheduled backups use a non-interactive path so they never block on a prompt.
- Pick an existing SSH key or generate a dedicated ed25519 key per repository.

**Backups and archives**

- Manual backups with exclude patterns, progress, and cancellation.
- Any number of schedules per repository, installed as launchd agents. Retries with backoff, native notifications on success or failure, and a "Run now" button.
- Archive browser with full-tree search, Quick Look previews, and restore of single files or whole folders.
- File history: see every version of a path across all archives.
- Treemap of what takes up space inside an archive.
- Prune, check, compact, delete, break-lock, and passphrase change from the UI.

**Menu bar and widget**

- Runs as a menu bar app. The menu shows every schedule with its last result and next run, and lets you start a backup or open the main window.
- A WidgetKit overview widget for the desktop and Notification Center.

**BorgBase panel**

- All your BorgBase repositories with quota bars, region, encryption, last activity and stale flags.
- Create, rename, edit (quota, inactivity alerts, access control, scheduled compaction) and delete repositories. Manage SSH keys. Import any repository into BorgMac in one click.

**BorgBox panel**

- Connect to a self-hosted BorgBox daemon: server stats, active sessions, repositories.
- Check, prune, compact and break-lock as server-side jobs with live logs. Browse remote archives. Toggle append-only mode. Configure stale-backup webhook alerts and test them.
- Register a new repository (BorgMac generates the key, registers it with the daemon and adopts the repo) or import an existing one.
- Automation panel: create and manage server-side maintenance schedules (periodic check and compact) across all your BorgBox servers.

## How it works

- Every operation is a `borg` subprocess run with `--log-json`. Borg's JSON log lines are parsed into readable messages for the UI.
- The passphrase is passed through `BORG_PASSPHRASE` in the child's environment. It is never written to disk or to the command line.
- For SSH repositories with a chosen key, BorgMac sets `BORG_RSH` to `ssh -i <key> -o IdentitiesOnly=yes`.
- Scheduled backups are launchd agents at `~/Library/LaunchAgents/com.carlos.BorgMac.backup.<repo>.<schedule>.plist`. Each one runs the app binary headless with `--run-backup <repo> <schedule>`, which performs the backup and exits without showing any UI.
- The app is not sandboxed, because it has to run `borg` and `ssh` and read whatever you back up. The widget extension is sandboxed.

Files on disk:

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/BorgMac/` | Repository list, per-schedule status, widget snapshot |
| `~/Library/Caches/BorgMac/` | Cached archive manifests for the browser |
| `~/Library/Logs/BorgMac/` | One log per scheduled backup run |
| `~/Library/LaunchAgents/com.carlos.BorgMac.backup.*.plist` | Schedules |

Passphrases, API tokens and BorgBox credentials are in the Keychain, not in any of these files.

The launchd plists embed the absolute path of the app. If you move `BorgMac.app` after creating schedules, toggle each schedule off and on again so the plist is rewritten. A Homebrew install always lives in `/Applications`, so this does not come up.

## Build from source

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not committed.

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project BorgMac.xcodeproj -scheme BorgMac -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
```

Or open `BorgMac.xcodeproj` in Xcode after generating it. The app ends up in Xcode's DerivedData folder; add `-derivedDataPath build` to keep it inside the repository (`build/` is gitignored).

Layout:

- `BorgMac/Models` — repository, archive, tree and cache models.
- `BorgMac/Services` — `BorgClient` (the `borg` wrapper), Keychain, launchd scheduling, the headless backup runner, and the BorgBase and BorgBox API clients.
- `BorgMac/Views` — SwiftUI views, one file per sheet or panel.
- `BorgMacWidget` — the WidgetKit extension. `Shared/` holds the snapshot model both targets read.

## Releasing

`./release.sh <version>` builds a Release configuration, signs it with the Developer ID, notarizes and staples it, then tags `v<version>`, creates the GitHub release with the zip attached, and bumps version and sha256 in the cask at [prietus/homebrew-tap](https://github.com/prietus/homebrew-tap). `NOTARIZE=0` and `PUBLISH=0` give you a local-only build.

## License

[MIT](LICENSE).
