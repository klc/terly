# Changelog

This file summarizes Terly's release history. Its format is loosely inspired by
[Keep a Changelog](https://keepachangelog.com/); release sections are
automatically included in GitHub Release notes and the Sparkle appcast by
`release.yml` (see `docs/RELEASING.md`).

## Unreleased

Work in progress on the next release. `release.yml` only extracts a section
whose heading exactly matches the tag's version, so this heading is inert until
the changes below are moved under a real version number at tag time.

### Added
- Open different connections side by side in the current terminal tab: use the
  sidebar shortcut menu, ⌥-click for a vertical split, ⌥⇧-click for a horizontal
  split, or drag a connection onto the nearest pane edge. If no terminal tab is
  visible, the connection opens in a normal new tab instead.
- Workspaces: save the current tabs and split panes as a named workspace and
  reopen the whole layout later with one click. Each pane can carry its own
  startup — a free-form command, one of your startup flows, or nothing — so a
  single host can open with `htop` in one pane, logs in another, and the
  project directory in a third. Save from the session header button or the
  sidebar's Workspaces section; reopening appends to whatever is already open,
  and panes whose alias has left the SSH config are skipped with a notice.
- Record a terminal session from the session header. Each recording is a folder
  containing one [asciinema](https://docs.asciinema.org/) cast v2 file per pane,
  named after the pane's alias. The folder is created with owner-only permissions
  (`0700`) and each cast file with `0600`.
- A **Recordings** library in the General sidebar with recording metadata,
  multi-pane disclosure, Finder reveal, rename, and confirmed move-to-Trash
  actions. Its built-in asciicast v2 player supports play/pause, seeking, and
  1x/2x/4x playback while keeping files compatible with asciinema.
- A configurable recording root in **Settings → General**. Recordings default to
  `~/Library/Application Support/Terly/Recordings`; changing the root does not
  migrate existing recordings.
- Several recordings can run at once — one per terminal tab — and each carries a
  100 MB cap that stops it cleanly rather than filling the disk.
- A Help Center (**Help → Terly Help**, ⇧⌘/) covering connections, terminal
  controls, menus, and keyboard shortcuts, plus a welcome tour shown on first
  launch and re-openable from the Help menu.
- A new tab button beside the split controls in the session header (⌘T) that
  opens the active pane's connection again in its own tab.

### Fixed
- Selecting **Local Terminal** in the sidebar returns to the terminal you left
  instead of stacking up another tab on every click, so coming back from
  another section no longer drops you into a fresh shell. Use the new tab
  button when a second local terminal is what you want.
- Recording no longer dies silently when the configuration is reloaded: the
  recorder used to be owned by a view that gets torn down in that case, so every
  byte after the reload was lost.
- Recording writes now happen off the main thread on a serial queue with a
  buffer, instead of a blocking disk write in the terminal output hot path.
- Panes in a session nobody is recording no longer allocate a copy of every
  output chunk just to have it discarded.

### Changed
- Starting a recording no longer opens a save panel. Terly creates a dated folder
  automatically under the configured recording root, and stopped recordings are
  opened from the sidebar instead of being revealed automatically in Finder.
- Keyboard shortcuts now come from a single registry that both the bindings and
  the Help guide read from, so documented shortcuts cannot drift from real ones.
- The sidebar's general section is now called **General**; **Workspaces** takes
  its place as the name for saved tab-and-pane layouts.

### Removed
- Connection groups. Saved workspaces replace them and additionally allow the
  same host in several panes with different startup commands, which groups
  could not express. Existing group definitions are not migrated; recreate the
  layout on screen and save it as a workspace.

## 1.1.1

An urgent compatibility fix for pane navigation in release builds.

### Fixed
- Restored mouse-based pane switching when SwiftTerm's Metal renderer receives
  the click instead of its parent terminal view.
- Pinned CI and release jobs to Xcode 26.3 so development, validation, and
  published artifacts use the same SwiftUI/AppKit toolchain generation.

## 1.1.0

A usability release that makes the terminal workspace and file transfers faster,
safer, and more persistent.

### Added
- Resize terminal panes by dragging, reset them to a 50/50 split with a
  double-click, and rearrange panes by dragging.
- Reorder tabs by dragging, rename them with a double-click, and restore their
  order and names when the workspace is reopened.
- New keyboard shortcuts for pane zoom, directional pane navigation, and tab
  selection.
- Open file transfers from the active terminal connection and upload files or
  folders by dropping them from Finder onto a terminal pane.

### Fixed
- Prevented a cancelled transfer from restarting or being recorded more than
  once when a late process callback arrived.
- Fixed automatic transfer retries starting immediately instead of respecting
  the 2/4-second exponential backoff.
- Restored remote destination checks and overwrite confirmation for uploads
  started from the form or Finder drop; selections targeting the same remote
  path are now rejected.
- Fixed pane resize calculations to use the coordinate space of the entire
  terminal grid.
- Removed stale drag state left by cancelled tab drags and now accept only valid
  session UUID payloads.
- Terminal workspace persistence errors are now shown to the user instead of
  being silently ignored.
- Moved sync change notifications onto the main run loop, removing the warning
  caused by updating `@Published` state from a background thread.

## 1.0.0

Initial release. A native SwiftUI SSH workspace combining `~/.ssh/config`
management, an embedded terminal, file transfers, tunnels, and runbooks.

### Configuration management
- Losslessly parses SSH configuration files while preserving comments and
  unknown directives.
- Form-based editing for hosts, `Match` blocks, and global directives, with
  multi-level grouping for host aliases.
- Write-through saving: every edit is backed up and written to disk immediately;
  the raw configuration editor and change history/preview are available from
  the menu bar.
- External change detection, backup history and restoration, atomic writes, and
  `0600` file permissions.
- Temporary validation with `ssh -G` and explicit confirmation for `Match exec`.

### Connection diagnostics and trust center
- Resolved `ssh -G` settings, DNS, ProxyJump, IdentityFile permissions, SSH
  agent and `known_hosts` fingerprint checks, and an end-to-end connection test.
- Copy a redacted diagnostics report to the clipboard, with timeout and
  cancellation support for every network step.

### Terminal
- Embedded SwiftTerm-based terminal; each connection runs in its own SSH process
  on a separate tab.
- Horizontally and vertically splittable panes with `⌘`-based synchronized
  selection and input sharing.
- Font, size, and color theme settings (System, Solarized Dark/Light, Dracula,
  Nord, One Dark, and Gruvbox Dark) with live preview.
- In-terminal search (`⌘F`).
- A status bar for unexpected disconnections, one-click reconnect, optional
  automatic reconnect with exponential backoff, and network recovery detection.

### Connection groups and Quick Access
- Named connection groups that can open together in separate tabs or as panes
  within a single tab.
- `⌘K` Quick Access with fuzzy search by alias, `HostName`, `User`, or group
  name, plus favorites and recent items.

### Startup flows and key setup
- Per-host startup flows with user switching, directory changes, and shell
  command steps, including preview and one-time skip.
- Key Setup Wizard for generating ed25519 keys with `ssh-keygen`, optionally
  adding them to the agent, and securely copying them to `authorized_keys`
  (`ssh-copy-id` is not used); private keys are never read by any code path.
- `SSH_ASKPASS` bridge with a secure password dialog for SCP/SFTP/checksum
  operations on password-protected or agentless hosts, plus a separate host-key
  confirmation dialog; passwords are never persisted.

### File transfers
- Upload and download individual files and folders over SCP/SFTP, with a
  concurrency-limited queue, automatic retries, and overwrite confirmation.
- New Folder, Rename, and Delete actions in the remote directory browser
  (deletion is limited to empty folders; recursive deletion is not supported).
- Persistent transfer history for the latest 200 records, retry support, path
  redaction, and partial-file cleanup for cancelled transfers.
- Optional post-transfer checksum verification.

### Tunnel manager and snippets
- Local, remote, and dynamic port forwarding with individual start/stop controls
  and connection-triggered automatic startup.
- `⌘S` snippet palette; secret values are stored in Keychain.

### Runbooks
- Confirmed, safe command execution across multiple hosts.

### Testing and CI
- Unit tests for `SSHConfigCore` and the application (`swift test` and
  `xcodebuild test`), an XCUITest UI smoke test, transfer queue and reconnect
  integration tests using fake process executors, and a performance regression
  test for configurations containing 1,000 hosts.

### Versioning and distribution
- Version metadata (`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`) and Hardened
  Runtime in `project.yml`; local development builds remain ad-hoc signed.
- Sparkle integration with “Check for Updates” and automatic update options in
  Settings (real keys must be supplied by Mustafa; see `docs/RELEASING.md`).
- Tag-triggered `release.yml` workflow for signing, notarization, DMG/ZIP
  packaging, and appcast publishing once all required secrets are configured.
