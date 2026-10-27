#!/usr/bin/env bash
# Installs the privileged half of the Omarchy OpenVPN widget.
#
#   sudo bash install.sh                    install or update
#   sudo bash install.sh --gp-passwordless  same, plus the polkit rule that lets
#                                           you connect approved GlobalProtect
#                                           portals without a password
#   sudo bash install.sh --uninstall        remove everything it installed
#
# Afterwards the panel can list profiles (through the cache, no prompt) and
# trigger writing actions through pkexec (the shell's auth dialog).
#
# The widget works without this. Status, throughput and connection details need
# no privileges at all; only profile management does.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=/usr/local/bin/multivpn-admin
POLICY=/usr/share/polkit-1/actions/software.nepomuk.multivpn.policy
UNIT_DIR=/etc/systemd/system
# gpclient runs the DNS wrapper as root, so the copy it runs lives here, owned
# by root, and never in the plugin directory the user can write.
LIB_DIR=/usr/local/lib/multivpn
GP_BIN=/usr/local/bin/multivpn-gp
GP_APPROVE=/usr/local/sbin/multivpn-gp-approve
GP_RULE=/etc/polkit-1/rules.d/49-multivpn-gp.rules
GP_APPROVED_DIR=/etc/multivpn

[[ $EUID -eq 0 ]] || { echo "Please run with sudo." >&2; exit 1; }

mode=install
case "${1:-}" in
  "") ;;
  --uninstall) mode=uninstall ;;
  --gp-passwordless) mode=passwordless ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

# Earlier versions installed under an omarchy-* name, which claimed a namespace
# this plugin does not own. Clean those up whichever way the script is run.
remove_legacy() {
  systemctl disable --now omarchy-vpn-cache.path 2>/dev/null || true
  rm -f /usr/local/bin/omarchy-vpn-admin \
        /usr/share/polkit-1/actions/org.omarchy.vpnadmin.policy \
        "$UNIT_DIR/omarchy-vpn-cache.path" "$UNIT_DIR/omarchy-vpn-cache.service"
  rm -rf /var/lib/omarchy-vpn
}

if [[ $mode == uninstall ]]; then
  systemctl disable --now multivpn-cache.path 2>/dev/null || true
  rm -f "$BIN" "$POLICY" "$GP_BIN" "$GP_APPROVE" "$GP_RULE" \
        "$UNIT_DIR/multivpn-cache.path" "$UNIT_DIR/multivpn-cache.service"
  rm -rf /var/lib/multivpn "$LIB_DIR" "$GP_APPROVED_DIR" /run/multivpn
  remove_legacy
  systemctl daemon-reload
  echo "removed."
  exit 0
fi

# The rule names a user, so it has to be someone's own sudo, not a root shell.
if [[ $mode == passwordless ]]; then
  rule_user=${SUDO_USER:-}
  if [[ ! $rule_user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [[ $(id -u "$rule_user" 2>/dev/null) == 0 ]]; then
    echo "--gp-passwordless needs to be run with sudo from your own user." >&2
    exit 1
  fi
fi

remove_legacy

command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 1; }

# The helpers run as root through pkexec or sudo, so they must not be owned by,
# or writable for, the calling user — that would be a privilege escalation.
install -o root -g root -m 0755 "$HERE/multivpn-admin" "$BIN"
install -o root -g root -m 0755 "$HERE/multivpn-gp" "$GP_BIN"
install -o root -g root -m 0755 "$HERE/multivpn-gp-approve" "$GP_APPROVE"
install -o root -g root -m 0644 "$HERE/software.nepomuk.multivpn.policy" "$POLICY"
install -o root -g root -m 0644 "$HERE/multivpn-cache.path" "$UNIT_DIR/"
install -o root -g root -m 0644 "$HERE/multivpn-cache.service" "$UNIT_DIR/"
install -d -o root -g root -m 0755 "$LIB_DIR" "$GP_APPROVED_DIR"
install -o root -g root -m 0755 "$HERE/gpclient-dns-wrapper" "$LIB_DIR/"

# Without --gp-passwordless an existing rule is left as it is: updating the
# helpers from the panel's setup button should not quietly take it away.
if [[ $mode == passwordless ]]; then
  tmp=$(mktemp)
  sed "s/@USER@/$rule_user/g" "$HERE/49-multivpn-gp.rules.in" > "$tmp"
  install -o root -g root -m 0644 "$tmp" "$GP_RULE"
  rm -f "$tmp"
fi

systemctl daemon-reload
systemctl enable --now multivpn-cache.path

# Fill it once so the panel has something to show straight away.
"$BIN" refresh

count=$(python3 -c "
import json
print(len(json.load(open('/var/lib/multivpn/profiles.json'))['profiles']))")

echo "installed:"
echo "  $BIN"
echo "  $GP_BIN"
echo "  $GP_APPROVE"
echo "  $POLICY"
echo "  $UNIT_DIR/multivpn-cache.{path,service}  (enabled)"
echo "  $LIB_DIR/gpclient-dns-wrapper"
echo "  /var/lib/multivpn/profiles.json          ($count profiles)"
if [[ -f $GP_RULE ]]; then
  echo "  $GP_RULE  (passwordless GlobalProtect for $(sed -n 's/.*subject.user == "\(.*\)".*/\1/p' "$GP_RULE"))"
  echo
  echo "Approve a portal with: sudo $GP_APPROVE approve <host>"
fi
