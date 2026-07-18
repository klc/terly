# Terly

A native SwiftUI SSH workspace for macOS: `~/.ssh/config` management, embedded terminal, file transfers, port forwarding, and runbooks. (Formerly: SSH Configurator.)

## Features

- Parses existing config losslessly; comments and unknown directives are preserved.
- Form-based editing for Host list, `HostName`, `User`, `Port`, `IdentityFile`, and `ProxyJump`.
- Multi-level collapsible grouping of Host aliases based on `-` components (e.g., `ams-api-prod-1` → `ams → api → prod`).
- Dedicated workspaces for global directives, `Match` blocks, and `Include` lines.
- Raw text editor for the entire config, and a preview showing diffs between the disk file and the in-memory working copy (e.g., after a write conflict); both are accessible from the menu bar (**File → Raw Config Editor…** / **File → Change History/Preview…**).
- Working copy model with undo support for unsaved changes before saving.
- External change detection, backup history/restore, atomic saves, and `0600` file permissions.
- `ssh -G` validation using a temporary config. Requires explicit confirmation for running local commands if it contains `Match exec`.
- Connection Diagnostics and Trust Center; displays resolved `ssh -G` settings alongside their source lines, checking DNS, ProxyJump, IdentityFile permissions, SSH agent, `known_hosts` fingerprint, and end-to-end connectivity.
- Copies diagnostic reports to the clipboard with usernames, local paths, and sensitive commands redacted; all network operations support timeouts and cancellation.
- Opens the selected Host alias in the built-in SwiftTerm terminal.
- File and folder upload/download via SCP/SFTP for the selected Host; features local file selection, a remote directory browser, and overwrite confirmations.
- Runs each connection as a direct SSH process in separate tabs of the built-in terminal.
- Terminal opens directly by clicking the connection row in the sidebar; gear icon on the row opens connection settings in a modal.
- Creates named connection groups; group configuration allows opening connections in separate terminal tabs or together in split panes within a single tab.
- Active terminal can be split horizontally or vertically; splitting opens a new connection with the same SSH alias.
- Panes can be selected for synchronized input by holding the `⌘` key and clicking; keyboard inputs and pasted commands are sent to all selected terminals simultaneously.
- Custom Connection Startup Flows in Host settings: steps for switching users with `sudo -iu`, navigating to a remote directory, and running shell commands with failure policies can be added, deleted, and reordered.
- Auto-startup can be previewed per host before connecting, skipped once for a single connection or an entire group, and manually re-executed in an open terminal.
- In group connections, each host uses its own profile; synchronized terminal input is blocked until all startup flows complete, preventing commands from duplicating to incorrect panes.
- Fuzzy search by alias, `HostName`, `User`, or connection group name in the quick access window opened via `⌘K`; allows launching connect, settings, file transfer, and diagnostic actions directly from results.
- Favorites and recently used connections are prioritized in quick access; catalog updates automatically when the config is refreshed internally or externally.
- Uploads and downloads directories in addition to individual files; transfers run in a queue with a configurable concurrency limit (1-5), and failed transfers are automatically retried.
- Tunnel Manager supporting Local (`-L`), Remote (`-R`), and Dynamic (`-D`) port forwarding; tunnels can be started/stopped individually and set to automatically start with connections.
- Snippet palette opened via `⌘S` allows quickly inserting frequently used commands/text into the terminal; snippets are managed in a separate section.
- SSH Key Setup Wizard: generates ed25519 key pairs for a host, optionally adds them to the SSH agent, and copies the public key to the server's `authorized_keys` file; accessible from the host settings modal and the sidebar right-click menu.
- Manual or automatic update checking using Sparkle via the **Updates** tab in the Settings window (see Versioning and Updates).
- Config/tunnel/snippet/runbook/startup flow synchronization to the user's private git repository via the **Sync** tab in Settings; no intermediate server is used, and authentication relies entirely on the system git/SSH keys (see Git Synchronization).

## Security

- The application never reads the contents of private key files.
- Backups are stored in `~/Library/Application Support/Terly/Backups` with `0600` permissions.
- When restoring a backup, the current config is first backed up as a new backup.
- Refuses to write directly to config files that are symbolic links.
- The application operates with write-through: there is no separate **Save** action; every edit action (adding/deleting/copying hosts, field edits, applying from raw config or section editors, adding/removing Includes) is written directly to `~/.ssh/config` as soon as it is completed. Before each write, the current content is automatically backed up; if a write fails due to an external conflict, changes remain only in the in-memory working copy and an error is shown.
- Terminal commands are executed using individual process arguments without shell concatenation.
- SCP/SFTP transfers and checksum verification on hosts that may prompt for password/passphrase work via an `SSH_ASKPASS` bridge: the `terly-askpass.sh` helper bundled in the app classifies the prompt sent by ssh/scp/sftp via `argv[1]` — showing a secure password input dialog for passwords/passphrases, and a separate confirmation dialog for server identity (`yes/no`) host key confirmation, returning the user's choice exactly (automatic "yes" is never sent). Entered values are only written to the helper's stdout; they are never written to argv, environment, log files, or disk. If the user cancels the dialog, the helper returns empty output with a non-zero exit code. Since multiple transfers might request passwords simultaneously, the helper executes sequentially using a simple filesystem lock (mkdir): while one dialog is open, other pending prompts wait silently in line, preventing multiple windows from opening at once.
- The Runbook executor and Connection Diagnostics center intentionally continue using `BatchMode=yes`: since runbooks can run on multiple hosts simultaneously, a password prompt would hang execution or cause a concurrent password storm; diagnostics do not require password prompts because they report agent/key status separately.
- Diagnostics do not automatically modify or accept host key records; end-to-end checks use `StrictHostKeyChecking=yes`.
- SSH helper processes, SCP, and SFTP share a common timeout, cancellation, output gathering, and error classification layer.
- Startup profiles are kept in `~/Library/Application Support/Terly/startup-flows.json` as atomic JSON with `0600` permissions; they are not written to `~/.ssh/config`.
- Startup metadata is not a vault for passwords, tokens, sudo passwords, or private key contents. The interface warns about secret-like commands; the app does not capture or store sudo passwords.
- Profile UUIDs are preserved when changing an alias within the application. If the config changes externally and an alias disappears, the profile is displayed as orphaned and can be re-associated with a new alias.
- Quick access favorites/recents metadata is stored atomically in `~/Library/Application Support/Terly/quick-access.json`, with the directory set to `0700` and the file set to `0600` permissions; this is separate from startup flow metadata.
- The Key Setup Wizard does not use `ssh-copy-id`; when copying to the server, it only reads the `.pub` file and feeds it to `ssh` via stdin. The private key itself is never opened or read in any code path. Overwriting is only possible with explicit user consent.
- Git synchronization **does not store** its own git credentials: the system git (`/usr/bin/git`) is called with an argv array (no shell parsing), and authentication is fully delegated to the user's own SSH keys/credential helper. With `GIT_TERMINAL_PROMPT=0`, headless processes will not hang on password prompts and will return with a clear error instead. Private keys, `known_hosts`, transfer history, workspace layouts, and secret snippet values are never included in the sync set — snippet `isSecret` values are already never written to JSON (kept in Keychain), so the sync layer does not need to redact them. Non-fast-forward pulls never merge automatically; remote changes are first compared to local files (diff preview), and are only applied after explicit approval, backing up the current local state beforehand. There is no line-based automatic merging on conflicts (diverged history) — the user chooses one of three options: (a) back up local and pull remote, (b) replace remote with local — which does not use `git push --force` but rather creates a new merge commit, (c) cancel. Regardless of the choice, the local state is backed up before applying.
- **Bootstrap Paradox**: To use sync on a new machine, you must first have remote access (e.g., GitHub) — meaning an SSH key (added to agent) or HTTPS credential helper must already be set up. This cannot be solved by synchronization itself: generate/add a key using the **Key Setup Wizard** (see above), register the public key on GitHub, and then link the remote URL under the Sync tab.

## In-App Terminal

The terminal view currently uses SwiftTerm. Since the terminal session and SSH process model are decoupled from the rendering engine, a `libghostty`-based engine can be integrated under the same contract in the future.

Font, font size, and color themes (System, Solarized Dark/Light, Dracula, Nord, One Dark, Gruvbox Dark) can be customized via the Settings window opened with `⌘,`. The preview updates live with sample text and 16 ANSI colors. Theme changes apply immediately to all open terminal tabs (including background/hidden tabs) and persist across launches; theme file import/export is not supported in this version.

Connections without startup flows or those skipped once open directly via `/usr/bin/ssh -- <alias>`. If an automated flow is active, the app sends a single remote bootstrap command using `-tt` instead of typing steps with delays into the PTY. Closing a terminal tab terminates the associated SSH process; connections do not persist in the background when the app is closed.

The working copy must be saved before opening a connection; SSH always uses the `~/.ssh/config` file on disk.

### Auto-Reconnect

If a terminal pane disconnects unexpectedly (remote host closes connection, network drops, or `exit` is typed in the remote shell — all handled identically), a status bar appears in the terminal view: **"Connection lost"** header, **Reconnect** button, and **Close Pane** button. If you close the tab/pane manually, this bar will not appear.

The **"Auto-reconnect on this host"** checkbox below the bar is a per-host setting for the SSH alias and is **disabled** by default; it is stored in `~/Library/Application Support/Terly/auto-reconnect.json` (atomic write, file `0600`/directory `0700`). When enabled, it attempts to auto-reconnect up to 5 times on unexpected disconnects with incremental backoff (2s → 4s → 8s → 16s → 32s, capped at 60s); the countdown is displayed on the bar and can be canceled at any time using **Cancel**. If the reconnected session remains active for 15 seconds, the attempt counter resets; if all 5 attempts fail, auto-reconnect stops for that disconnect, requiring manual "Reconnect". When network connectivity is restored, a pending auto-reconnect countdown triggers immediately; if auto-reconnect is disabled for a pane, only a "Network restored" suggestion is shown — the app never connects on its own without user consent. Reconnection follows the same startup flow behavior as a manual "Reconnect". All pending timers are canceled when the application is closed; past countdowns never reappear upon session restore.

## Connection Startup Flow

You can define steps in the **Startup Flow** section of the Host settings (accessible via the gear icon on the connection row). The switch user step can only be used once and must be the first step. Directory and user fields are validated separately; empty or unsupported sequences are silently ignored. Directories are protected with centralized shell quoting, while the "Run command" field is intentionally executed as remote shell syntax.

The builder combines all steps into the same remote shell context, leaving the terminal interactive with `exec "${SHELL:-/bin/sh}" -l` at the end. If `sudo` requires a password, the prompt is shown in the terminal. The active startup step, completion, or failure (with exit code) is displayed in the terminal title. Manual re-execution actions are sent only to the active pane and are not replicated through synchronized input.

## Quick Connect Finder

You can open the Quick Access window from anywhere in the app using `⌘K`. As you type, concrete Host aliases are searched by their name, `HostName`, and `User` fields, while connection groups are searched by their group name. `↑`/`↓` changes selection, `Enter` performs the default **Connect** action, and `Esc` closes the window. Wildcard and negative Host patterns are not displayed as connection results.

The star button toggles favorites. Successfully opened single and group connections are added to the recents list. When an alias is renamed within the application, its quick access ID, favorites status, and history are preserved; aliases removed externally disappear and are not automatically re-associated.

## File Transfer

You can open the file transfer page using the **Transfer Files** action in the toolbar when a Host is selected. For uploads, choose local files or folders from Finder and select the remote destination folder via the in-app SFTP browser; the destination file name is pre-populated and editable. For downloads, select the remote file in the browser, and the standard macOS Save dialog will suggest the correct file name. Recently used local and remote folders are remembered.

Transfers are executed in a queue: multiple files/folders are transferred concurrently up to a configurable limit (1-5), and pending or active transfers display live percentage/speed progress. Failed transfers are automatically retried a few times; permanently failed or canceled transfers can be manually restarted from the queue. Directory transfers can be performed using SCP (`-r`) or SFTP; SFTP directory transfers use a separate worker. Overwrite confirmation is shown only when a file with the same name exists at the destination.

This version does not support storing passwords: if no SSH agent or key is present, a password dialog will open via the `SSH_ASKPASS` bridge during transfer (see the Security section); the entered password is not stored anywhere permanently. If a transfer is canceled, partial files may remain locally or remotely; check the relevant paths.

The **History** tab in the transfer page records every completed, permanently failed, and canceled transfer (pending/active transfers are not written to history). Up to 200 records are stored atomically in `~/Library/Application Support/Terly/transfer-history.json` (file `0600`/directory `0700`) and persist across application restarts. The **"Re-transfer"** action on each record adds a new job to the queue with the same parameters; if the local source file for an upload no longer exists, a clear error is shown immediately without queuing (for downloads, source files on the remote server cannot be pre-validated and are left to normal transfer error handling). If **"Mask Paths"** is checked, only the **visual representation** in this list shortens home directories to `~` and obscures username components with `•••` — this is purely visual; `transfer-history.json` continues to store the raw (unmasked) path since "Re-transfer" requires the actual path. **"Clear History"** prompts for confirmation before deleting the record list, leaving transferred or partial files untouched.

For canceled or permanently failed **single file** transfers, a **"Delete partial file…"** action appears in the history log; this targets only the destination path of that specific transfer (using `FileManager` for local files, and sftp `rm` for remote files) and asks for confirmation by showing the full path before deleting. This option is not offered for directory transfers — instead, a warning is shown indicating that manual cleanup is required (due to recursive deletion risks).

In the remote directory browser (when selecting transfer targets), you can perform **Rename** and **Delete** actions via the right-click menu or the "..." button on the row; **New Folder** is a separate button on the toolbar. Deleting always prompts for confirmation, displaying the file name and full remote path. Directory deletion works only on **empty** directories (sftp `rmdir`); the app does not delete directories recursively — attempting to delete a non-empty directory will display a "Directory not empty" error. The Delete key also opens the deletion confirmation dialog when a file is selected.

## Tunnel Manager

You can create Local (`-L`), Remote (`-R`), and Dynamic (`-D`) forward definitions in the **Tunnels** section of the sidebar. Each tunnel binds to a destination Host alias and can be started or stopped individually; if "Auto Connect" is checked, the tunnel is automatically established when the corresponding connection opens. The default local bind address is `127.0.0.1`; a security warning is shown in the UI if a publicly accessible address like `0.0.0.0` or `::` is selected.

## Snippets

While in the terminal, you can search and insert frequently used command or text snippets into the active pane using `⌘S`. Snippets are managed (added, edited, deleted) as key/value pairs in the **Snippets** section of the sidebar.

## Key Setup Wizard

The **Setup Key…** action in a host row's right-click menu or the host settings modal opens a three-step wizard:

1. **Generate**: Runs `/usr/bin/ssh-keygen -t ed25519 -f <path> -C <comment>` using individual process arguments. The default path is `~/.ssh/id_ed25519_<alias>` (alias is sanitized for safe filenames); path and comment are editable. Passphrase input is fully delegated to ssh-keygen's own prompt and displayed as a dialog via the `SSH_ASKPASS` bridge — the app never sees or stores the passphrase. If a file already exists at the target path, it is overwritten only after explicit confirmation.
2. **Add to Agent (optional)**: If checked, runs `/usr/bin/ssh-add <private key path>`. `ssh-add` reads the key file itself; the app does not access the contents.
3. **Copy to Server**: `ssh-copy-id` IS NOT USED. Instead, only the `<path>.pub` file is read (the private key is never read in any code path) and its content is fed via stdin to `/usr/bin/ssh -- <alias> sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'`. Before running, the target host, remote command to execute, and the public key text are displayed as a preview.

After successful copying, a check automatically runs `ssh -o BatchMode=yes -- <alias> true` to verify that passwordless login works, displaying the result. Finally, the wizard offers to update the host's `IdentityFile` field to the new key; this update is applied only with user confirmation through the normal write-through editing flow. If the Connection Diagnostics center detects that there are no usable keys in the agent and authentication was rejected, it displays a suggestion prompting the user to launch this wizard.

## Git Synchronization

You can link your own private git repository (e.g., GitHub) as a sync backend from the **Sync** tab in the Settings window. No middleman servers, free history: the app automatically commits on changes, and you push when you want. On a new machine or after a clean install, you can connect the same repo to restore your settings.

**⚠️ Repository must be private.** Everything synced here (Host definitions, tunnel/snippet/runbook/startup flow metadata) is committed to the remote repository, and **git history is permanent**. Deleting a file from the repository later does not automatically erase its historical revisions (which requires tools like `git filter-repo` or `BFG`). If linked to a public repository, this information will become publicly accessible.

**What is synced**: `~/.ssh/config` + any `Include`d files (only those located under `~/.ssh`; others residing outside or carrying names like private keys or `known_hosts` are silently skipped and listed in warnings), startup flows, quick access favorites, auto-reconnect settings, tunnels, runbooks, and snippets (excluding values of snippets marked as secret, which are only stored in Keychain and never written to JSON).

**What is NOT synced**: private key contents (never read/copied), transfer history, terminal workspace layouts (machine-specific), `known_hosts` (changes frequently and creates commit noise), local backups (`Backups/`), and the Keychain.

**Cadence**: Changes are not pushed immediately on every edit. Instead, a local commit is created after 30 seconds of inactivity (debounce). Pushing is **manual** by default ("Sync Now"); automatic pushing can be enabled via a setting. Pulls occur on application startup and manually, performing **fast-forward only** — never auto-merging.

**Remote changes are never applied silently**: Pulling only updates the local synchronization repository. What changes will be made is shown in a side-by-side preview screen (current vs. incoming content); actual files are not touched without your explicit approval. The current local state is automatically backed up before approval. The preview also flags incoming config `IdentityFile` paths that do not exist on the current machine (a basic, text-based check that skips paths containing `ssh_config` tokens; refer to the Connection Diagnostics center for full runtime resolution).

**Conflict (diverged history)**: No line-based automatic merging. Three options are provided: (a) back up local and accept remote, (b) replace remote with local — this option **not using** `git push --force` but instead advances via a new merge commit, (c) cancel. Whichever is chosen, the current local state is backed up before application.

**Bootstrap Paradox**: To use this feature on a new machine, you first need access to the remote repository (e.g., GitHub) — meaning an SSH key (added to agent) or HTTPS credential helper must already be set up. This cannot be solved by synchronization itself: generate/add a key using the **Key Setup Wizard** (see above), register the public key on GitHub, and then link the remote URL under the Sync tab.

## Versioning and Updates

The application version is tracked in `project.yml` under `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`. Local development builds remain signed ad-hoc (`CODE_SIGN_IDENTITY="-"`), while official Developer ID signing is applied in CI only when a release tag (`v*`) is pushed to `.github/workflows/release.yml`.

Updates are distributed via [Sparkle](https://github.com/sparkle-project/Sparkle). Manual update checks and toggling automatic updates can be managed from the **Updates** tab in the Settings window. The `SUFeedURL` and `SUPublicEDKey` values in `project.yml` are currently **placeholders**; they must be updated with the actual appcast URL (`https://klc.github.io/terly/appcast.xml`) and the public key generated by `generate_keys`. A guard detecting placeholder public keys disables the update check button with a "Update channel not configured yet" warning until a valid key is provided.

For the end-to-end release process, required GitHub secrets, and manual steps required by Mustafa, see **`docs/RELEASING.md`**.

## Development

```sh
xcodegen generate
open SSHConfigurator.xcodeproj
swift test
```

The `xcodegen generate` command recreates the Xcode project from the source-controlled `project.yml` file.

## Testing and CI

- Unit tests can be run in two ways: `swift test` (SwiftPM, fast) or
  `xcodebuild -project SSHConfigurator.xcodeproj -scheme SSHConfigurator test -only-testing:SSHConfigCoreTests -only-testing:SSHConfiguratorTests`
  (Xcode toolchain, which covers running `SSHConfiguratorTests` inside the actual `Terly.app` using `TEST_HOST`). Both test targets use `GENERATE_INFOPLIST_FILE: YES` — without this, `xcodebuild test` fails during the codesign phase because it cannot sign the test bundle (`swift test` is unaffected since it runs bundleless).
- The UI smoke test (`SSHConfiguratorUITests`, `XCUITest`) covers a single scenario: app launches → sidebar is displayed → `⌘K` opens/`Esc` closes quick access → `⌘,` opens/closes the Settings window. It requires no active SSH connection and only performs read-only actions, never writing to the user's actual `~/.ssh/config`. Locally:
  `xcodebuild -project SSHConfigurator.xcodeproj -scheme SSHConfigurator -configuration Debug CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES test -only-testing:SSHConfiguratorUITests`.
  UI tests (unlike unit tests) require a valid (even if ad-hoc) codesign signature **and** "Developer Mode" enabled on the machine for `testmanagerd` to attach; otherwise, the test runner immediately terminates with a "Test crashed with signal kill before establishing connection" error. To enable Developer Mode once: `sudo /usr/sbin/DevToolsSecurity -enable`.
- CI (`.github/workflows/ci.yml`) runs two jobs: `build-and-test` (build + `swift test` + the `xcodebuild test` command above) and a separate `ui-smoke` job (which enables Developer Mode and runs UI smoke tests with ad-hoc signing).
- The transfer queue (`TransferQueueEngineIntegrationTests`) and the auto-reconnect chain (`AutoReconnectChainIntegrationTests`) are tested end-to-end using mock implementations of `SSHProcessExecuting` and `ReconnectScheduling`: validating queuing → mock success/failure → status + history records, and disconnection → backoff → mock success → counter resets without starting actual `scp` or `ssh` processes.
- `SSHConfigDocumentPerformanceTests` parses and groups a synthetic config with 1000 hosts; the threshold (5s) is intentionally generous to accommodate slow CI runners (local execution takes ~25ms) — the goal is not micro-performance tracking, but catching potential O(n²) regressions.
