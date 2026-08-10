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

## ⚡ Start here — one command for everything

```bash
bash <(curl -fsSL https://sico.securytik.com/ubuntu)
```

**Ubuntu Assistant** lists every snippet below, you pick one, and it runs — exactly
as if you had pasted that snippet yourself. One URL to remember instead of twenty.

That first run also leaves the menu behind as a permanent command, so you never
paste the URL again:

```bash
ubuntu-assistant          # or just press ↑ and Enter
```

<sub>It installs to `/usr/local/bin` (or `~/.local/bin` without root). Remove it with
`sudo rm /usr/local/bin/ubuntu-assistant`.</sub>

### It works offline

That same first run copies **every snippet** to
`/usr/local/share/ubuntu-essentials` (`~/.local/share/…` without root) — about
**520 KB** of shell, no packages. From then on the menu and the snippets are read
from disk, so the box needs no network to run them:

- **Fully offline**: `ssh-control`, `network-ip`, `dns-setup`, `firewall`,
  `server-triage`, `user-manage`, the `ssh-key-*` trio, `disk-show`,
  `disk-rescue`, `swap-setup`, `hostname`, `time-date` — the local-configuration
  tools you reach for precisely when the box has no route out.
- **Still needs the network**, because of what they *install*, not how they are
  fetched: `docker-compose`, `webmin-install`, `cloudflared-install`,
  `python-install`, `update-upgrade`, the VPN wizards, and `samm-install`.

The copy refreshes itself when it is more than 7 days old, and `r` at the menu
prompt updates it on demand. A refresh that fails leaves the working copy exactly
as it was — the offline copy is never worse for having tried.

<sub>Prefer the long way? It's the same file:
`bash <(curl -fsSL https://raw.githubusercontent.com/mhdhaidarah/Ubuntu-Essentials/main/ubuntu-assistant.sh)`</sub>

---

Each file in this repo is a small, self-contained **bash** snippet that performs
one task — from a one-liner (`df -h`) to a full interactive wizard (Netplan,
PPPoE, WireGuard, SMB/SSHFS). They're grouped by task type below.

You can use any snippet **three ways**:

### 1. The assistant
`bash <(curl -fsSL https://sico.securytik.com/ubuntu)` — pick from a menu (above).

### 2. Copy the command structure
Open the file, copy its contents, paste into your terminal. Nothing leaves your
machine.

### 3. Run it straight from this repo
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mhdhaidarah/Ubuntu-Essentials/main/<file>.sh)
```
> **Why `bash <(curl …)` and not `curl … | bash`?** Several of these snippets are
> interactive (they ask you questions). Process substitution keeps your keyboard
> connected to the script, so the prompts work. A plain pipe would feed the
> script itself to `read` and the wizard would get no answers. The scripts call
> `sudo` internally where they need root.

---

## Start here

| Snippet | What it does |
|---|---|
| [`ubuntu-assistant.sh`](ubuntu-assistant.sh) | Menu of every snippet below — pick one and it runs, exactly as if you'd pasted it. `bash <(curl -fsSL https://sico.securytik.com/ubuntu)`, then just `ubuntu-assistant` from then on. |

## System & maintenance

| Snippet | What it does |
|---|---|
| [`server-triage.sh`](server-triage.sh) | **What is wrong with this box** — read-only: load, memory, disk and inodes, failed units, OOM kills, recent errors, listening ports, clock sync, ending with what to look at first. |
| [`disk-rescue.sh`](disk-rescue.sh) | Find what filled the disk and reclaim it: biggest dirs and files, journal, apt cache, old kernels (a full `/boot` breaks apt itself), Docker, and deleted-but-still-open files. |
| [`swap-setup.sh`](swap-setup.sh) | Add a swap file sized from RAM, or zram for a small slow-disk VPS; remove one; tune swappiness. Persisted properly. |
| [`backup-restore.sh`](backup-restore.sh) | Archive `/etc /root /home /opt` to a local, SMB/SSHFS or remote destination, schedule it with retention, verify an archive, and restore — to a staging directory by default. |
| [`update-upgrade.sh`](update-upgrade.sh) | Refresh package lists, full-upgrade, purge obsolete packages, turn on unattended security updates, then run the Ubuntu release upgrade. Fully non-interactive. |
| [`hostname.sh`](hostname.sh) | Interactive wizard to set the hostname and keep `/etc/hosts` in sync. |
| [`time-date.sh`](time-date.sh) | Pick a timezone (Middle-East presets or custom IANA) and enable NTP. |
| [`disk-show.sh`](disk-show.sh) | Show mounted filesystems and free space (`df -h`). |
| [`disk-extend-100.sh`](disk-extend-100.sh) | Grow the root LVM volume to use 100% of the free space. |
| [`python-install.sh`](python-install.sh) | Install Python 3 + pip/venv and the common build toolchain. |

## Networking

| Snippet | What it does |
|---|---|
| [`firewall.sh`](firewall.sh) | ufw wizard driven by what is actually listening, with presets for SAMM and web. **Refuses to enable the firewall until SSH is allowed** — the classic way to lose a remote box. |
| [`net-diag.sh`](net-diag.sh) | Loss and jitter sampled over time, `mtr`, per-resolver DNS timing, MTU discovery, and port reachability. |
| [`dns-setup.sh`](dns-setup.sh) | Shows which layer actually owns DNS — `systemd-resolved`, netplan or `resolv.conf` — then sets it, tests it, and puts it back without leaving the box unable to resolve. |
| [`network-ip.sh`](network-ip.sh) | Netplan wizard: pick an interface, set IPv4/IPv6 (DHCP / static / SLAAC), DNS, with `netplan try` safe-apply and backups. |
| [`speedtest.sh`](speedtest.sh) | Install and run an internet speed test; optionally bind the test to a specific uplink. |

## VPN & uplinks

| Snippet | What it does |
|---|---|
| [`pppoe-client.sh`](pppoe-client.sh) | PPPoE client wizard — add/remove a persistent dialer on any interface. |
| [`l2tp-client.sh`](l2tp-client.sh) | L2TP/IPsec VPN client wizard (strongSwan + xl2tpd), reboot-persistent, multi-VPN, auto-redial after a drop. |
| [`l2tp-client-once.sh`](l2tp-client-once.sh) | **Temporary** L2TP client — a support tunnel that lives in `/tmp`, dies on reboot, and tears down with `sudo l2tp-once-down`. Nothing persistent is written. |
| [`l2tp-server.sh`](l2tp-server.sh) | L2TP **server** (LNS) — add/remove users, see who's online, optional IPsec PSK. NATs its clients out to the internet. |
| [`wireguard-client.sh`](wireguard-client.sh) | WireGuard tunnel wizard — generate keys, add/remove tunnels, enable on boot. |
| [`wireguard-server.sh`](wireguard-server.sh) | WireGuard **server** — add/remove peers, print a peer's config + QR, list who's online. NATs its clients out to the internet. |

> The two **server** snippets turn the box into a real gateway for their clients:
> they enable IP forwarding, MASQUERADE the VPN subnet out of the WAN interface and
> clamp MSS, so a connected client reaches the internet *through* the server.

## Login & access

| Snippet | What it does |
|---|---|
| [`ssh-control.sh`](ssh-control.sh) | The whole SSH server in one menu: install it, change the port (socket-activated systems included), root-login policy, the **login model** — password only, key only, either, or the *both-required lockdown* (key **and** password, in that order) — fail2ban, an allow-list, idle timeout, host keys, and config backup/restore. |
| [`user-manage.sh`](user-manage.sh) | List login-capable accounts and who is online, then add or delete a user, or grant and revoke sudo. Refuses to delete root or the account you logged in with. |
| [`ssh-key-create.sh`](ssh-key-create.sh) | Generate an ed25519 keypair for the current user, then print the public key with three ready-made ways to install it on the remote server. |
| [`ssh-key-add.sh`](ssh-key-add.sh) | Paste a public key into any user's `authorized_keys`, with validation, correct permissions and a fingerprint back. Skips a key that is already there. |
| [`ssh-key-list.sh`](ssh-key-list.sh) | List a user's authorized keys by type, fingerprint and comment, then remove one or all of them. Backs the file up before every change. |

> Every change `ssh-control.sh` makes goes into a drop-in
> (`/etc/ssh/sshd_config.d/99-ssh-control.conf`), is validated with `sshd -t`
> *before* anything is reloaded, and is undone by one file removal. The ways to
> lock yourself out are refused outright: passwords off with no key installed
> anywhere, an allow-list without your own account, and a both-required lockdown
> when no account holds **both** a key and a usable password.

## File sharing

| Snippet | What it does |
|---|---|
| [`smb-client.sh`](smb-client.sh) | Mount a remote SMB/CIFS share with a credentials file and systemd automount. |
| [`sshfs-client.sh`](sshfs-client.sh) | Mount a remote path over SSHFS (key-based), reconnecting systemd automount. |
| [`share-server.sh`](share-server.sh) | Turn this box into an SMB + SSHFS file server with per-share users. |

## SAMM

| Snippet | What it does |
|---|---|
| [`samm-install.sh`](samm-install.sh) | Pre-flight this box — OS, RAM, disk, free ports, no existing install — then fetch the latest release and run the official installer. |
| [`samm-health.sh`](samm-health.sh) | Read-only diagnosis for support: install type and version, every service, PostgreSQL, FreeRADIUS sockets, the panel, headroom and the error board. |

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
disks. Tested on Ubuntu 22.04 / 24.04 / 26.04.

<p align="center">
  <sub>Part of the <a href="https://securytik.com">Securytik</a> ecosystem ·
  Generate router &amp; server configs at
  <a href="https://sico.securytik.com">sico.securytik.com</a></sub>
</p>
