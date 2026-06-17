<p align="center">
  <img src="sico-logo.svg" alt="SICO" width="84" height="84">
</p>

<h1 align="center">Ubuntu Essentials</h1>

<p align="center">
  Ready-to-run command snippets for the everyday Ubuntu server tasks — one copy
  away, or one <code>curl</code> away.
  <br>
  Curated for <a href="https://sico.securytik.com">SICO</a>, the Securytik
  Interactive Configuration Optimizer.
</p>

---

Each file in this repo is a small, self-contained **bash** snippet that performs
one task — from a one-liner (`df -h`) to a full interactive wizard (Netplan,
PPPoE, WireGuard, SMB/SSHFS). They're grouped by task type below.

You can use any snippet **two ways**:

### 1. Copy the command structure
Open the file, copy its contents, paste into your terminal. Nothing leaves your
machine.

### 2. Run it straight from this repo
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mhdhaidarah/Ubuntu-Essentials/main/<file>.sh)
```
> **Why `bash <(curl …)` and not `curl … | bash`?** Several of these snippets are
> interactive (they ask you questions). Process substitution keeps your keyboard
> connected to the script, so the prompts work. A plain pipe would feed the
> script itself to `read` and the wizard would get no answers. The scripts call
> `sudo` internally where they need root.

---

## System & maintenance

| Snippet | What it does |
|---|---|
| [`update-upgrade.sh`](update-upgrade.sh) | Update package lists, full-upgrade, autoremove, then run a release upgrade. |
| [`hostname.sh`](hostname.sh) | Interactive wizard to set the hostname and keep `/etc/hosts` in sync. |
| [`time-date.sh`](time-date.sh) | Pick a timezone (Middle-East presets or custom IANA) and enable NTP. |
| [`disk-show.sh`](disk-show.sh) | Show mounted filesystems and free space (`df -h`). |
| [`disk-extend-100.sh`](disk-extend-100.sh) | Grow the root LVM volume to use 100% of the free space. |
| [`python-install.sh`](python-install.sh) | Install Python 3 + pip/venv and the common build toolchain. |

## Networking

| Snippet | What it does |
|---|---|
| [`network-ip.sh`](network-ip.sh) | Netplan wizard: pick an interface, set IPv4/IPv6 (DHCP / static / SLAAC), DNS, with `netplan try` safe-apply and backups. |
| [`speedtest.sh`](speedtest.sh) | Install and run an internet speed test; optionally bind the test to a specific uplink. |

## VPN & uplinks

| Snippet | What it does |
|---|---|
| [`pppoe-client.sh`](pppoe-client.sh) | PPPoE client wizard — add/remove a persistent dialer on any interface. |
| [`l2tp-client.sh`](l2tp-client.sh) | L2TP/IPsec VPN client wizard (strongSwan + xl2tpd), reboot-persistent. |
| [`wireguard-client.sh`](wireguard-client.sh) | WireGuard tunnel wizard — generate keys, add/remove tunnels, enable on boot. |

## File sharing

| Snippet | What it does |
|---|---|
| [`smb-client.sh`](smb-client.sh) | Mount a remote SMB/CIFS share with a credentials file and systemd automount. |
| [`sshfs-client.sh`](sshfs-client.sh) | Mount a remote path over SSHFS (key-based), reconnecting systemd automount. |
| [`share-server.sh`](share-server.sh) | Turn this box into an SMB + SSHFS file server with per-share users. |

## Apps & services

| Snippet | What it does |
|---|---|
| [`docker-compose.sh`](docker-compose.sh) | Install Docker Engine + the Compose plugin from Docker's official repo. |
| [`cloudflared-install.sh`](cloudflared-install.sh) | Install Cloudflare Tunnel (`cloudflared`) from Cloudflare's apt repo. |
| [`webmin-install.sh`](webmin-install.sh) | Install the Webmin web admin panel. |

---

## A word of caution

These run real commands on a real machine — several need root and change
networking, storage, or installed packages. **Read a snippet before you run it**,
and prefer a server you can recover (console/KVM) when changing networking or
disks. Tested on Ubuntu 22.04 / 24.04 LTS.

<p align="center">
  <sub>Part of the <a href="https://securytik.com">Securytik</a> ecosystem ·
  Generate router &amp; server configs at
  <a href="https://sico.securytik.com">sico.securytik.com</a></sub>
</p>
