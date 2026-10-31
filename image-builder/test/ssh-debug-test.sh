#!/bin/bash

# omarchy-ssh-debug: key-only sshd for the first user's GitHub keys, retried
# until it works, never touching the user's own keys, opt-out by file. System
# tools are fakes; the keys are made here with ssh-keygen when it is present.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=$ROOT/builder/ssh-debug/omarchy-ssh-debug
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

me=$(id -un)
bin=$work/bin calls=$work/calls home=$work/home
mkdir -p "$bin" "$home" "$work/etc"
fake() {
  printf '#!/bin/bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$calls" "${2:-}" >"$bin/$1"
  chmod +x "$bin/$1"
}
cat >"$bin/getent" <<GETENT
#!/bin/bash
[[ \$1 == passwd ]] || exit 2
{
  echo "root:x:0:0::/root:/bin/bash"
  echo "nobody:x:65534:65534::/:/usr/bin/nologin"
  [[ -e $work/no-user ]] || echo "$me:x:1000:1000::$home:/bin/bash"
} | if [[ -n \${2:-} ]]; then grep "^\$2:"; else cat; fi
GETENT
chmod +x "$bin/getent"
fake sshd 'if [[ $1 == -T ]]; then [[ -e '"$work"'/weak-sshd ]] && echo "passwordauthentication yes" || printf "PasswordAuthentication no\\nkbdinteractiveauthentication no\\npermitrootlogin no\\npubkeyauthentication yes\\n"; fi'
fake systemctl 'if [[ $1 == cat ]]; then exit 0; fi'
fake ufw
fake hostnamectl 'echo omarchy-mini'
fake pacman
cp "$ROOT/builder/install-timing/omarchy-install-timing" "$bin/omarchy-install-timing"
printf '1.00 1.00\n' >"$work/uptime"

if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -q -t ed25519 -N '' -C one -f "$work/k1" && ssh-keygen -q -t ed25519 -N '' -C two -f "$work/k2"
  key1=$(cut -d' ' -f1,2 "$work/k1.pub") key2=$(cut -d' ' -f1,2 "$work/k2.pub")
  rm -f "$work/k1" "$work/k2"
else
  # Well-formed blobs without ssh-keygen: the type string at offset 4.
  blob() { { printf '\0\0\0\013ssh-ed25519\0\0\0\040'; printf '%032d' "$1"; } | base64 | tr -d '\n'; }
  key1="ssh-ed25519 $(blob 1)" key2="ssh-ed25519 $(blob 2)"
fi
printf '%s\n%s\ncommand="rm -rf /" %s\nnot a key\n' "$key1" "$key2" "$key1" >"$work/github.keys"
cat >"$bin/curl" <<CURL
#!/bin/bash
echo "curl \$*" >>"$calls"
[[ -e $work/offline ]] && exit 6
[[ \${@: -1} == https://github.com/techmore.keys ]] || exit 22
cat "$work/github.keys"
CURL
chmod +x "$bin/curl"

export PATH="$bin:$PATH" OMARCHY_SSH_DEBUG_CONF=$work/etc/ssh-debug.conf
export OMARCHY_SSH_DEBUG_OPTOUT="$work/etc/no-ssh-debug" OMARCHY_SSH_DEBUG_STATE=$work/state
export OMARCHY_SSH_DEBUG_LOG=$work/log/ssh-debug.log OMARCHY_SSH_DEBUG_DROPIN=$work/sshd_config.d/20-omarchy-ssh-debug.conf
export OMARCHY_SSH_DEBUG_ATTEMPTS=2 OMARCHY_SSH_DEBUG_PAUSE=0
export OMARCHY_INSTALL_TIMING_LOG=$work/log/install-timing.jsonl OMARCHY_INSTALL_TIMING_UPTIME=$work/uptime
printf 'GITHUB_USER=techmore\n' >"$OMARCHY_SSH_DEBUG_CONF"
run() { set +e; "$script" >>"$work/out" 2>&1; status=$?; set -e; }

touch "$work/etc/no-ssh-debug"
run
(( status == 0 )) && [[ -e $work/state/done && ! -e $home/.ssh ]] || fail "the opt-out still set SSH up ($status): $(cat "$work/out")"
grep -q "opted out" "$work/log/ssh-debug.log" || fail "the opt-out was not logged"
rm -r "$work/etc/no-ssh-debug" "$work/state"
pass "the opt-out file stops it and is logged"

touch "$work/no-user"
run
(( status == 75 )) && [[ ! -e $work/state/done ]] || fail "it did not wait for the first user ($status)"
rm "$work/no-user"
touch "$work/offline"
run
(( status == 75 )) && [[ $(grep -c "^curl" "$calls") -eq 2 ]] || fail "it did not retry the fetch and wait ($status)"
[[ ! -e $work/sshd_config.d/20-omarchy-ssh-debug.conf ]] || fail "sshd was configured without keys"
rm "$work/offline"
pass "with no user or no network it retries later and leaves sshd off"

touch "$work/weak-sshd"
run
(( status == 1 )) && ! grep -q "^systemctl enable --now sshd" "$calls" || fail "sshd started though it would allow passwords ($status)"
rm "$work/weak-sshd" "$home/.ssh/authorized_keys"
pass "sshd stays off when its effective configuration would still allow passwords"

mkdir -p "$home/.ssh"
printf 'ssh-ed25519 AAAAuserownkey mine\n%s laptop\n' "$key2" >"$home/.ssh/authorized_keys"
run
(( status == 0 )) || fail "the setup failed ($status): $(cat "$work/log/ssh-debug.log")"
keys=$home/.ssh/authorized_keys
[[ $(sed -n 1p "$keys") == "ssh-ed25519 AAAAuserownkey mine" && $(sed -n 2p "$keys") == "$key2 laptop" ]] ||
  fail "the user's own keys changed"
[[ $(grep -c . "$keys") -eq 3 && $(sed -n 3p "$keys") == "$key1 github:techmore" ]] || fail "keys: $(cat "$keys")"
! grep -q 'command=' "$keys" || fail "a key with options was authorized"
[[ $(stat -f %Lp "$home/.ssh" 2>/dev/null || stat -c %a "$home/.ssh") == 700 ]] || fail ".ssh is not 0700"
[[ $(stat -f %Lp "$keys" 2>/dev/null || stat -c %a "$keys") == 600 ]] || fail "authorized_keys is not 0600"
grep -q "1 added, 1 already present, 2 refused" "$work/log/ssh-debug.log" || fail "the log does not say what it did"
pass "GitHub keys are added beside the user's own, validated, 0700/0600, and logged"

dropin=$work/sshd_config.d/20-omarchy-ssh-debug.conf
for setting in "PasswordAuthentication no" "KbdInteractiveAuthentication no" "PermitRootLogin no" "PubkeyAuthentication yes"; do
  grep -qx "$setting" "$dropin" || fail "the drop-in lacks $setting"
done
grep -q "^systemctl enable --now sshd.service" "$calls" || fail "sshd was not enabled"
grep -q "^systemctl enable --now avahi-daemon.service" "$calls" || fail "mDNS was not enabled"
grep -q "^ufw limit 22/tcp" "$calls" && grep -q "^ufw allow 5353/udp" "$calls" || fail "the firewall was not opened"
! grep -q "^pacman" "$calls" || fail "openssh was reinstalled though sshd is present"
grep -q "ssh omarchy-mini" "$work/log/ssh-debug.log" || grep -q "@omarchy-mini.local" "$work/log/ssh-debug.log" || fail "the address was not logged"
[[ $(jq -r 'select(.phase == "ssh_ready") | "\(.user) \(.github_user) \(.keys)"' "$OMARCHY_INSTALL_TIMING_LOG") == "$me techmore 2" ]] ||
  fail "ssh_ready not recorded"
[[ -e $work/state/done ]] || fail "not marked done"
pass "sshd is key-only and enabled, mDNS and the firewall are open, and ssh_ready is recorded"

before=$(cat "$keys")
run
[[ $(cat "$keys") == "$before" && $(grep -c ssh_ready "$OMARCHY_INSTALL_TIMING_LOG") -eq 1 ]] || fail "a second run changed the keys or the record"
pass "a second run adds nothing"

printf 'GITHUB_USER=bad/name\n' >"$OMARCHY_SSH_DEBUG_CONF"
run
(( status == 1 )) || fail "an invalid GitHub user was accepted"
pass "an invalid GitHub user name is refused"

# What stage_ssh_debug puts in the image passes the lab-access scan that every
# non-lab image must pass: no key, no authorized_keys, no enabled sshd.
tree=$work/tree
install -Dm0755 "$script" "$tree/usr/local/bin/omarchy-ssh-debug" 2>/dev/null ||
  { mkdir -p "$tree/usr/local/bin" && cp "$script" "$tree/usr/local/bin/omarchy-ssh-debug"; }
mkdir -p "$tree/etc/systemd/system/multi-user.target.wants" "$tree/etc/omarchy"
cp "$ROOT/builder/ssh-debug/omarchy-ssh-debug.service" "$tree/etc/systemd/system/"
ln -s ../omarchy-ssh-debug.service "$tree/etc/systemd/system/multi-user.target.wants/omarchy-ssh-debug.service"
printf 'GITHUB_USER=techmore\n' >"$tree/etc/omarchy/ssh-debug.conf"
PYTHONPATH=$ROOT/builder python3 -c '
import sys, lab_access
from pathlib import Path
found = lab_access.findings(Path(sys.argv[1]))
sys.exit(f"lab-access findings: {found}" if found else 0)' "$tree" || fail "the staged files trip the lab-access scan"
pass "the image carries nothing the lab-access scan refuses"
