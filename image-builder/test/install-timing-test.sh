#!/bin/bash

# omarchy-install-timing merges the installer's ESP log once, and records each
# Linux milestone once, with fake system tools.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
timing=$ROOT/builder/install-timing/omarchy-install-timing
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

mkdir -p "$work/bin" "$work/log"
printf '#!/bin/bash\necho 6.18.0-elementaryos-mseries\n' >"$work/bin/uname"
printf '#!/bin/bash\necho "Startup finished in 3.1s (kernel) + 9.2s (userspace) = 12.3s"\n' >"$work/bin/systemd-analyze"
printf '#!/bin/bash\necho "OpenGL renderer string: Apple M4 (G16G)"\n' >"$work/bin/eglinfo"
chmod +x "$work/bin/"*
printf '12.34 40.00\n' >"$work/uptime"
printf '{"phase":"image_write","seconds":61.5}\n' >"$work/esp.jsonl"
export PATH="$work/bin:$PATH" OMARCHY_INSTALL_TIMING_UPTIME="$work/uptime"
export OMARCHY_INSTALL_TIMING_LOG="$work/log/install-timing.jsonl" OMARCHY_INSTALL_TIMING_ESP="$work/esp.jsonl"
log=$OMARCHY_INSTALL_TIMING_LOG
phases() { jq -r .phase "$log" | paste -sd' ' -; }

"$timing" boot
"$timing" boot
[[ $(phases) == "image_write linux_first_boot" ]] || fail "first boot merged $(phases)"
[[ $(jq -r 'select(.phase == "image_write").source' "$log") == macos ]] || fail "the ESP records are not marked macos"
[[ $(jq -r 'select(.phase == "linux_first_boot").kernel' "$log") == 6.18.0-elementaryos-mseries ]] || fail "kernel not recorded"
pass "first boot merges the ESP log and records itself once"

"$timing" desktop
"$timing" desktop
[[ $(jq -r 'select(.phase == "desktop_ready").renderer' "$log") == "Apple M4 (G16G)" ]] || fail "renderer not recorded"
pass "the desktop milestone records the renderer once"

if "$timing" claude; then fail "recorded Claude Code without claude answering"; fi
printf '#!/bin/bash\necho "2.1.0 (Claude Code)"\n' >"$work/bin/claude"
chmod +x "$work/bin/claude"
"$timing" claude
"$timing" claude
[[ $(phases) == "image_write linux_first_boot desktop_ready claude_code_answering" ]] || fail "milestones $(phases)"
jq -e . "$log" >/dev/null || fail "the log is not JSON lines"
pass "Claude Code is recorded once it answers, and only once"

if "$timing" nonsense 2>/dev/null; then fail "an unknown milestone was accepted"; fi
pass "an unknown milestone is refused"

# First-login Claude Code: Anthropic's installer (a fake here), retried while
# the network is down, then recorded once; the owner can opt out.
first_login=$ROOT/builder/install-timing/omarchy-first-login-claude-code
rm -f "$work/bin/claude"
export HOME="$work/home" XDG_STATE_HOME= XDG_CONFIG_HOME= OMARCHY_CLAUDE_CODE_PAUSE=0 OMARCHY_CLAUDE_CODE_ATTEMPTS=3
unset XDG_STATE_HOME XDG_CONFIG_HOME
mkdir -p "$HOME"
cp "$timing" "$work/bin/omarchy-install-timing"
cat >"$work/bin/curl" <<'CURL'
#!/bin/bash
count=$HOME/curl-calls
echo x >>"$count"
(( $(wc -l <"$count") >= 2 )) || exit 7
printf 'mkdir -p "$HOME/.local/bin"\nprintf "#!/bin/bash\\necho 2.1.0 \\(Claude Code\\)\\n" >"$HOME/.local/bin/claude"\nchmod +x "$HOME/.local/bin/claude"\n'
CURL
chmod +x "$work/bin/curl"
jq -c 'select(.phase != "claude_code_answering")' "$log" >"$work/log.tmp" && mv "$work/log.tmp" "$log"

mkdir -p "$HOME/.config/omarchy"
touch "$HOME/.config/omarchy/no-claude-code"
"$first_login"
[[ ! -e $HOME/curl-calls ]] || fail "the opt-out still ran the installer"
pass "the owner can opt out of installing Claude Code"

rm "$HOME/.config/omarchy/no-claude-code"
"$first_login" || fail "the first-login install failed"
[[ $(wc -l <"$HOME/curl-calls") -eq 2 ]] || fail "the installer was not retried after a failed fetch"
[[ -x $HOME/.local/bin/claude ]] || fail "Claude Code was not installed"
[[ $(jq -r 'select(.phase == "claude_code_answering").version' "$log") == "2.1.0 (Claude Code)" ]] || fail "Claude Code not recorded"
[[ -e $HOME/.local/state/omarchy/claude-code-installed ]] || fail "the install was not marked done"
"$first_login"
[[ $(wc -l <"$HOME/curl-calls") -eq 2 ]] || fail "a later login fetched the installer again"
[[ $(grep -c claude_code_answering "$log") -eq 1 ]] || fail "Claude Code recorded twice"
pass "first login installs Claude Code, retrying the fetch, and records it once"
