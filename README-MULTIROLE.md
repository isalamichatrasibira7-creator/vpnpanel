# Multi-Role Multi-VPS Panel

This modified project keeps the original VPN installer and adds a role-based multi-VPS dashboard.

## Roles

- `hybrid`: Main dashboard + local node status API. Recommended for the VPS you want to use as your main panel.
- `main`: Central dashboard only.
- `node`: Local VPN server status API only.

Every VPS can run the same files. Change role from **Panel Role / API Token** in the web panel.

## Install

```bash
sudo bash main-installer.sh
```

After install, open:

```text
http://YOUR_VPS_IP/vpn-panel
```

## Add another VPS

1. Install this same project on VPS2/VPS3.
2. Open VPS2/VPS3 panel.
3. Go to **Panel Role / API Token**.
4. Set role to `node` or `hybrid`.
5. Copy the Node API Token.
6. Open main VPS panel.
7. Go to **Multi VPS Servers**.
8. Add VPS name, IP, panel URL, and API token.

The main index dashboard refreshes data every 5 seconds in the background.

## Security note

This system does not store root usernames or root passwords for remote VPS nodes. Remote monitoring uses API tokens.
For production, use HTTPS on all panels.
