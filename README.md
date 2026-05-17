# VPN PRO Admin Installer

Run from the extracted folder on a clean Ubuntu/Debian VPS:

```bash
sudo bash -c 'REPO_RAW=https://raw.githubusercontent.com/isalamichatrasibira7-creator/vpnpanel/main bash <(curl -fsSL https://raw.githubusercontent.com/isalamichatrasibira7-creator/vpnpanel/main/main-installer.sh)'
```

Panel URL after install:

```text
http://YOUR_VPS_IP/vpn-panel
```

Default admin:

```text
openvpn / Easin112233@
```

Default VPN user:

```text
Easin / Easin112233@
```

Thank you...


## Multi-Role Multi-VPS Dashboard

This version includes a role-based system. Any installed VPS can be switched to `main`, `node`, or `hybrid` from the web panel.

- Use `hybrid` for the main VPS that also runs VPN services.
- Use `node` for remote VPS servers.
- Add remote VPS nodes from **Multi VPS Servers** using the Node API Token from **Panel Role / API Token**.
- The index dashboard updates multi-VPS counts and graphs every 5 seconds in the background.

See `README-MULTIROLE.md` for details.
