# Changelog

This file summarizes Terly's release history. Its format is loosely inspired by
[Keep a Changelog](https://keepachangelog.com/); release sections are
automatically included in GitHub Release notes and the Sparkle appcast by
`release.yml` (see `docs/RELEASING.md`).

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
