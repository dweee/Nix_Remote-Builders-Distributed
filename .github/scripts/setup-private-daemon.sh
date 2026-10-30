#!/usr/bin/env bash
# Run as root on a disposable GitHub-hosted builder after Determinate installs.
# The installer-managed netrc remains untouched and never receives our token.
set -euo pipefail
test "$(id -u)" = 0
source_file=${1:?private netrc source required}
refresh_source=${2:?trusted refresh script required}
test -f "$source_file"
test -f "$refresh_source"
state=/nix/var/nix/nix-remote-private
install -d -m 0700 "$state"
install -m 0600 "$source_file" "$state/attic.netrc"
install -m 0700 "$refresh_source" "$state/refresh.pl"
printf 'netrc-file = %s/combined.netrc\n' "$state" > "$state/nix.conf"
chmod 0600 "$state/nix.conf"
refresh=(/usr/bin/perl "$state/refresh.pl" "$state/attic.netrc" /nix/var/determinate/netrc "$state/combined.netrc")
"${refresh[@]}"

case "$(uname -s)" in
  Linux)
    install -d -m 0755 /etc/systemd/system/nix-daemon.service.d
    cat > /etc/systemd/system/nix-daemon.service.d/90-nix-remote-private.conf <<EOF
[Service]
Environment=NIX_USER_CONF_FILES=$state/nix.conf
ExecStartPre=/usr/bin/perl $state/refresh.pl $state/attic.netrc /nix/var/determinate/netrc $state/combined.netrc
EOF
    cat > /etc/systemd/system/nix-remote-private-refresh.service <<EOF
[Unit]
Description=Refresh private remote-builder Nix credentials
[Service]
Type=oneshot
ExecStart=/usr/bin/perl $state/refresh.pl $state/attic.netrc /nix/var/determinate/netrc $state/combined.netrc
EOF
    cat > /etc/systemd/system/nix-remote-private-refresh.timer <<'EOF'
[Unit]
Description=Retry remote-builder Nix credential refresh
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now nix-remote-private-refresh.timer
    systemctl restart nix-daemon.service
    ;;
  Darwin)
    plist=/Library/LaunchDaemons/systems.determinate.nix-daemon.plist
    test -f "$plist"
    staged=$(mktemp /Library/LaunchDaemons/.nix-remote-daemon.XXXXXXXX)
    trap 'rm -f "$staged"' EXIT
    cp "$plist" "$staged"
    if ! /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables' "$staged" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' "$staged"
    fi
    if /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:NIX_USER_CONF_FILES' "$staged" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:NIX_USER_CONF_FILES $state/nix.conf" "$staged"
    else
      /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:NIX_USER_CONF_FILES string $state/nix.conf" "$staged"
    fi
    /usr/bin/plutil -lint "$staged" >/dev/null
    chmod 0644 "$staged"
    mv -f "$staged" "$plist"
    trap - EXIT
    cat > /Library/LaunchDaemons/fail.monke.nix-remote-private-refresh.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>fail.monke.nix-remote-private-refresh</string>
<key>ProgramArguments</key><array><string>/usr/bin/perl</string><string>$state/refresh.pl</string><string>$state/attic.netrc</string><string>/nix/var/determinate/netrc</string><string>$state/combined.netrc</string></array>
<key>RunAtLoad</key><true/><key>StartInterval</key><integer>30</integer>
</dict></plist>
EOF
    chmod 0644 /Library/LaunchDaemons/fail.monke.nix-remote-private-refresh.plist
    launchctl bootout system/systems.determinate.nix-daemon
    # launchd can leave its Unix socket paths behind after bootout; the
    # Determinate installer removes these before bootstrapping as well.
    for socket in /var/run/determinate-nixd.socket /var/run/nix-daemon.socket; do
      if [ -S "$socket" ]; then rm -f "$socket"; fi
    done
    launchctl bootstrap system "$plist"
    launchctl bootstrap system /Library/LaunchDaemons/fail.monke.nix-remote-private-refresh.plist
    ;;
  *) echo 'Unsupported builder operating system.' >&2; exit 1 ;;
esac
