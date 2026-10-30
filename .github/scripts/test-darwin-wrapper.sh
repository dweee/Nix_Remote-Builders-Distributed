#!/usr/bin/env bash
# Disposable hosted Mac only: test launchd socket inheritance through an exec wrapper.
set -euo pipefail
[ "$(id -u)" = 0 ] && [ "$(uname -s)" = Darwin ]
: "${SUDO_USER:?Run with sudo from the hosted runner user}"
plist=/Library/LaunchDaemons/systems.determinate.nix-daemon.plist
backup=$(mktemp /private/tmp/nixd-plist.XXXXXXXX)
cp "$plist" "$backup"
wrapper=$(mktemp /private/tmp/nixd-wrapper.XXXXXXXX)
cleanup() {
  launchctl bootout system/systems.determinate.nix-daemon >/dev/null 2>&1 || :
  cp "$backup" "$plist"
  for socket in /var/run/determinate-nixd.socket /var/run/nix-daemon.socket; do [ ! -S "$socket" ] || rm -f "$socket"; done
  launchctl bootstrap system "$plist" >/dev/null 2>&1 || :
  rm -f "$backup" "$wrapper"
}
trap cleanup EXIT
cat > "$wrapper" <<'SCRIPT'
#!/bin/sh
set -eu
/usr/bin/perl /nix/var/nix/nix-remote-private/refresh.pl /nix/var/nix/nix-remote-private/attic.netrc /nix/var/determinate/netrc /nix/var/nix/nix-remote-private/combined.netrc
exec /usr/local/bin/determinate-nixd daemon
SCRIPT
chmod 700 "$wrapper"
launchctl bootout system/systems.determinate.nix-daemon
for socket in /var/run/determinate-nixd.socket /var/run/nix-daemon.socket; do [ ! -S "$socket" ] || rm -f "$socket"; done
/usr/bin/python3 - "$plist" "$wrapper" <<'PY'
import plistlib,sys
p=sys.argv[1]
with open(p,'rb') as f: data=plistlib.load(f)
data['ProgramArguments']=['/bin/sh','-c','/bin/wait4path /nix/store && exec "$1"','wrapper',sys.argv[2]]
with open(p,'wb') as f: plistlib.dump(data,f)
PY
plutil -lint "$plist"
bootstrapped=false
attempt=0
while [ "$attempt" -lt 11 ]; do
  if launchctl bootstrap system "$plist"; then bootstrapped=true; break; fi
  attempt=$((attempt + 1))
  sleep 0.5
done
[ "$bootstrapped" = true ]
sudo -u "$SUDO_USER" env "PATH=/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin" python3 .github/scripts/test-determinate-cache.py
