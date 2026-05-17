#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "Run as root: sudo bash apply-critical-fixes.sh" >&2; exit 1; fi
APP_DIR="${PANEL_DIR:-/var/www/html/panel-admin}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -d "$SCRIPT_DIR/panel-admin" ]] || { echo "panel-admin folder not found beside this script" >&2; exit 1; }
mkdir -p "$APP_DIR" "$APP_DIR/api" "$APP_DIR/assets" "$APP_DIR/data" "$APP_DIR/downloads"
cp -a "$SCRIPT_DIR/panel-admin/." "$APP_DIR/"
cat >/usr/local/bin/oc-active-sessions.sh <<'OCACT'
#!/usr/bin/env bash
set -euo pipefail
SOCK="/run/occtl.socket"
[[ -S "$SOCK" ]] || exit 0
occtl -s "$SOCK" show users 2>/dev/null || true
OCACT
chmod +x /usr/local/bin/oc-active-sessions.sh
cat >/etc/sudoers.d/vpn-panel-oc-sessions <<'SUDO'
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-active-sessions.sh
SUDO
chmod 440 /etc/sudoers.d/vpn-panel-oc-sessions
visudo -cf /etc/sudoers.d/vpn-panel-oc-sessions >/dev/null
chown -R root:www-data "$APP_DIR" 2>/dev/null || true
find "$APP_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
find "$APP_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
chown -R www-data:www-data "$APP_DIR/data" 2>/dev/null || true
chmod -R 775 "$APP_DIR/data" 2>/dev/null || true
chown -R root:www-data "$APP_DIR/downloads" 2>/dev/null || chown -R www-data:www-data "$APP_DIR/downloads" 2>/dev/null || true
chmod -R 775 "$APP_DIR/downloads" 2>/dev/null || true
systemctl reload apache2 2>/dev/null || systemctl restart apache2 2>/dev/null || true
systemctl restart ocserv 2>/dev/null || true
echo "Critical fixes applied. OpenConnect count now ignores unauthenticated (none) sessions, and Add VPS accepts/validates node URL + token."
