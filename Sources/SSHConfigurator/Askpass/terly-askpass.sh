#!/bin/sh
#
# terly-askpass — SSH_ASKPASS helper bundled inside the Terly.app Resources.
#
# ssh/scp/sftp invoke this script (SSH_ASKPASS=<this path>,
# SSH_ASKPASS_REQUIRE=force) whenever they need to ask the user something and
# have no controlling terminal available. The prompt text ssh wants to show
# arrives as argv[1]; whatever this script prints to stdout (up to the first
# newline) is treated by ssh as the answer.
#
# SECURITY (do not weaken without re-reading WP2 in docs/DEVELOPMENT_PLAN_1.0.md):
#   - The secret the user types is written ONLY to this process's stdout.
#     It is never written to argv, an environment variable, a log file, or
#     any file on disk.
#   - The prompt text is passed to osascript via an environment variable
#     (not shell-interpolated into an -e string) so it can never be used to
#     inject additional AppleScript.
#   - Host-key confirmation ("yes/no") prompts are ALWAYS shown as an explicit
#     approve/reject dialog and the user's literal choice is returned
#     ("yes"/"no"). This script never auto-answers "yes".
#   - If the user cancels/dismisses a dialog, stdout stays empty and this
#     script exits non-zero. It also writes a non-secret marker to stderr
#     (TERLY_ASKPASS_CANCELLED) so SSHErrorClassifier can recognise a
#     user-cancelled prompt instead of misreporting a generic auth failure.
#     Stderr is inherited from the parent ssh/scp/sftp process, so the marker
#     surfaces in that process's own captured stderr — no new IPC needed.
#
# Serialization:
#   The app's transfer queue can run several transfers at once, each of which
#   spawns its own independent ssh/scp/sftp process and therefore its own
#   independent copy of this script. There is no shared Swift process to
#   coordinate through, so mutual exclusion is done here with a plain
#   mkdir-based lock (atomic on every POSIX filesystem, no extra tools
#   required): only one dialog is ever on screen at a time; the rest wait
#   quietly before presenting any UI. A lock older than the stale threshold
#   is assumed to be left over from a killed/crashed instance and is cleared.

PROMPT="${1:-Password required}"

# Dialog chrome (title/button text) is supplied by the app via these env
# vars so it can be localized through the app's own String Catalog — a
# shell script has no access to that catalog itself. English defaults cover
# the case where the helper is invoked without them (e.g. manual testing).
CONFIRM_TITLE="${TERLY_ASKPASS_CONFIRM_TITLE:-Terly — Server Identity Confirmation}"
YES_LABEL="${TERLY_ASKPASS_YES:-Yes}"
NO_LABEL="${TERLY_ASKPASS_NO:-No}"
AUTH_TITLE="${TERLY_ASKPASS_AUTH_TITLE:-Terly — Authentication}"
OK_LABEL="${TERLY_ASKPASS_OK:-OK}"
CANCEL_LABEL="${TERLY_ASKPASS_CANCEL:-Cancel}"

LOCK_DIR="${TMPDIR:-/tmp}/terly-askpass.lock"
LOCK_WAIT_STEPS=300      # 300 * 0.2s = up to 60s waiting for the lock
LOCK_STALE_SECONDS=90

acquired=0
i=0
while [ "$i" -lt "$LOCK_WAIT_STEPS" ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        acquired=1
        break
    fi
    if [ -d "$LOCK_DIR" ]; then
        lock_mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$((now - lock_mtime))
        if [ "$age" -gt "$LOCK_STALE_SECONDS" ]; then
            rmdir "$LOCK_DIR" 2>/dev/null || true
        fi
    fi
    i=$((i + 1))
    sleep 0.2
done

if [ "$acquired" -ne 1 ]; then
    echo "TERLY_ASKPASS_CANCELLED" >&2
    exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

is_host_key_prompt() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        *"(yes/no"*) return 0 ;;
        *) return 1 ;;
    esac
}

if is_host_key_prompt "$PROMPT"; then
    RESULT=$(ASKPASS_PROMPT="$PROMPT" ASKPASS_TITLE="$CONFIRM_TITLE" ASKPASS_YES="$YES_LABEL" ASKPASS_NO="$NO_LABEL" osascript <<'APPLESCRIPT'
    set promptText to (system attribute "ASKPASS_PROMPT")
    set titleText to (system attribute "ASKPASS_TITLE")
    set yesText to (system attribute "ASKPASS_YES")
    set noText to (system attribute "ASKPASS_NO")
    try
        set dialogResult to display dialog promptText with title titleText with icon caution buttons {noText, yesText} default button noText cancel button noText
        if button returned of dialogResult is yesText then
            return "yes"
        else
            return "no"
        end if
    on error
        return "no"
    end try
APPLESCRIPT
    )
    status=$?
    if [ "$status" -ne 0 ] || [ -z "$RESULT" ]; then
        echo "TERLY_ASKPASS_CANCELLED" >&2
        exit 1
    fi
    printf '%s\n' "$RESULT"
    exit 0
else
    RESULT=$(ASKPASS_PROMPT="$PROMPT" ASKPASS_TITLE="$AUTH_TITLE" ASKPASS_OK="$OK_LABEL" ASKPASS_CANCEL="$CANCEL_LABEL" osascript <<'APPLESCRIPT'
    set promptText to (system attribute "ASKPASS_PROMPT")
    set titleText to (system attribute "ASKPASS_TITLE")
    set okText to (system attribute "ASKPASS_OK")
    set cancelText to (system attribute "ASKPASS_CANCEL")
    try
        set dialogResult to display dialog promptText with title titleText default answer "" with hidden answer buttons {cancelText, okText} default button okText cancel button cancelText
        return text returned of dialogResult
    on error
        return ""
    end try
APPLESCRIPT
    )
    status=$?
    if [ "$status" -ne 0 ] || [ -z "$RESULT" ]; then
        echo "TERLY_ASKPASS_CANCELLED" >&2
        exit 1
    fi
    printf '%s\n' "$RESULT"
    exit 0
fi
