# ur-vps-ur-vpn

Your VPS, your VPN. One command on the server, one command on each device, and you have your own OpenVPN.

## Set up the server

SSH into your Linux VPS and run:

```bash
curl -fsSL https://raw.githubusercontent.com/Henryle-hd/ur-vps-ur-vpn/main/server.sh | sudo bash
```

There are no questions to answer. When it finishes, it prints what to do next and a block of text to paste on your device.

Prefer to read the script first, or clone it:

```bash
git clone https://github.com/Henryle-hd/ur-vps-ur-vpn.git
cd ur-vps-ur-vpn
sudo bash server.sh
```

> **Check your provider's firewall.** The script opens the port on the server itself, but it can't change a firewall in your provider's web panel (AWS security groups, Oracle security lists, Google Cloud firewall rules, Azure NSGs and so on). If your provider has one, allow **UDP 1194** there. The script tells you where to find it for your provider.

## Set up a device

Run the command for your system, then paste the block when it asks.

**macOS or Linux**, in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Henryle-hd/ur-vps-ur-vpn/main/client.sh | bash
```

**Windows**, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/Henryle-hd/ur-vps-ur-vpn/main/client.ps1 | iex
```

It installs OpenVPN, connects, checks that your traffic goes through the VPN, and reconnects by itself after a reboot. It will ask for your administrator password or approval once.

From a clone, use `bash client.sh` or `powershell -ExecutionPolicy Bypass -File client.ps1`.

**Phones:** run `ur-vpn show NAME --raw` on the server, save the output as `NAME.ovpn`, and import it into the OpenVPN Connect app.

## Everyday commands

On the server:

| Command | What it does |
| --- | --- |
| `sudo ur-vpn add laptop` | Create a client for another device and print its block |
| `sudo ur-vpn show laptop` | Print a client's block again (`--raw` for an `.ovpn` file) |
| `sudo ur-vpn revoke laptop` | Cut off a client right away |
| `sudo ur-vpn list` | List clients |
| `sudo ur-vpn start` | Start the VPN, and start it at boot |
| `sudo ur-vpn stop` | Stop the VPN, and keep it off, even after a reboot, until you start it |
| `sudo ur-vpn restart` | Restart the VPN. Clients reconnect by themselves, usually within seconds |
| `sudo ur-vpn status` | Show the service state and who is connected |
| `sudo ur-vpn logs` | Show the recent log |
| `sudo ur-vpn update` | Move to the latest release |
| `sudo ur-vpn version` | Print the installed version |
| `sudo ur-vpn uninstall` | Remove the VPN, its firewall rules and all certificates |

Use one client per device. The block is a login, so treat it like a password. A client that is already connected keeps working until you revoke it.

On macOS and Linux devices:

```text
ur-vpn start | stop | restart | status | logs | update | version | remove
```

On Windows, from an Administrator PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:ProgramData\ur-vpn\client.ps1" -Action stop
```

`-Action` can be `start`, `stop`, `restart`, `status`, `update`, `version` or `remove`.

On devices, `on` and `off` still work as other names for `start` and `stop`.

### Updating

`update` downloads the latest [release](https://github.com/Henryle-hd/ur-vps-ur-vpn/releases), checks it against the release's `SHA256SUMS`, and replaces the installed command. The checksum catches a damaged download. It can't protect against a compromised GitHub account, because the file and its checksum come from the same place.

On the server, it also rewrites the OpenVPN config and service from your saved settings. If either changed, the server restarts and clients reconnect by themselves, usually within seconds. If nothing changed, nobody is disconnected. If the new version won't start, the server goes back to the old one.

On a device, only the command changes, so the VPN stays connected, or stays off if you turned it off.

`update` doesn't upgrade OpenVPN itself. On Linux, use your package manager. On macOS, use `brew upgrade openvpn`. On Windows, install the new version from [openvpn.net](https://openvpn.net/community-downloads/).

## Options

The defaults suit most people. To change them, set these on the server before installing:

| Variable | Default | Purpose |
| --- | --- | --- |
| `VPN_HOST` | detected public IP | Address clients connect to, such as a domain name |
| `VPN_PROTO` | `udp` | `udp` is faster. `tcp` gets through more restrictive networks |
| `VPN_PORT` | `1194`, or the next free port | Port to listen on |
| `VPN_DNS` | `1.1.1.1 9.9.9.9` | DNS servers for clients |
| `VPN_CLIENT` | `client1` | Name of the first client |

For example, on networks that block VPN traffic, TCP on port 443 looks most like normal web traffic:

```bash
curl -fsSL https://raw.githubusercontent.com/Henryle-hd/ur-vps-ur-vpn/main/server.sh | sudo env VPN_PROTO=tcp VPN_PORT=443 bash
```

Settings are read at install time. To change them later, run `sudo ur-vpn uninstall` and install again, then set up your devices again.

## What it supports

**Server:** Ubuntu, Debian, Rocky, AlmaLinux, RHEL, Oracle Linux, CentOS Stream, Fedora, Amazon Linux 2023, openSUSE, Arch and Alpine, plus most distros based on them. It needs root, IPv4 and a TUN device. On OpenVZ or LXC plans you may have to turn on TUN/TAP in your VPS panel; the script tells you if so. Alpine needs `apk add bash curl` first.

**Client:** macOS (installs Homebrew if you don't have it), Windows 10, 11 and Server, and any Linux with systemd.

See [Testing](#testing) for what has actually been run on each system.

## What the server script does

1. Installs OpenVPN from your distro's packages, plus a pinned, SHA-256-verified copy of Easy-RSA so certificates work the same on every distro.
2. Finds your network interface, public IP, a free port, and a tunnel subnet that doesn't overlap your networks.
3. Creates a private certificate authority, server certificate and first client.
4. Turns on IP forwarding and NAT.
5. Adds firewall rules using whichever of firewalld, nftables, ufw or iptables is in use, and labels the port for SELinux if needed.
6. Starts a service that runs at boot, confirms it's up, and prints your next steps.

Running the script again is safe. If it's already installed, nothing changes and you get the block again. If an earlier run stopped partway, it picks up from there.

## Security

- **Certificates:** ECDSA P-256 with mutual authentication, and revocation that is checked on every connection.
- **Encryption:** AES-256-GCM, AES-128-GCM or ChaCha20-Poly1305, with TLS 1.2 or newer. Compression is off because of the VORACLE attack.
- **Hidden control channel:** each client has its own `tls-crypt-v2` key, so the server ignores anyone without one, and port scanners can't easily tell it's a VPN.
- **Least privilege:** OpenVPN runs as `nobody` inside a systemd sandbox. The CA key stays in a root-only folder that OpenVPN can't read.
- **No leaks:** all IPv4 and IPv6 traffic and DNS go through the tunnel. If the server has no IPv6, clients' IPv6 is blocked rather than sent around the VPN.
- **Client isolation:** devices on the VPN can't reach each other.
- **Safe for SSH:** the script only adds rules. It never changes your default firewall policy or SSH settings, so it can't lock you out.
- **Windows installer:** its signature is verified before it runs.

## Troubleshooting

**The client says it didn't connect.** It's nearly always the provider's firewall. Allow the VPN port in their web panel. The client keeps retrying and connects once it's open.

**"TUN device is not available".** Turn on TUN/TAP in your VPS control panel and reboot. If a kernel update was just installed, rebooting is enough.

**Connected, but websites don't load.** Run `sudo ur-vpn logs` on the server. If a custom nftables setup has a `policy drop`, it needs rules for the VPN too; the installer warns you about this.

**Pasting on Windows.** If Windows warns about pasting multiple lines, choose "Paste anyway". Or copy the block and press Enter at the prompt, and it reads the clipboard.

## Testing

`tests/e2e.sh` runs the scripts in two Docker containers with systemd and checks a real tunnel: NAT, DNS, IPv6 blocking, hidden paste, re-runs, revocation and uninstall.

```bash
tests/e2e.sh ubuntu:24.04 debian:13
```

CI runs these on every push, and a merge to `main` publishes a release only if they all pass:

- **Real tunnels:** Ubuntu 24.04 and 26.04, Debian 13, Rocky 9, AlmaLinux 10, Fedora 43, Amazon Linux 2023 and openSUSE Leap 16, plus TCP on port 443, a client without IPv6, ufw, nftables and firewalld. These run in containers on amd64.
- **macOS:** profile decoding under bash 3.2, and DNS and launchd setup using stand-ins for the system tools. It doesn't connect a real VPN.
- **Windows:** profile decoding, the real signed OpenVPN install, and the permissions on the private key file. It doesn't connect a real VPN.

Not tested yet:

- A real VPN connection from macOS or Windows
- SELinux or AppArmor in enforcing mode, and cloud provider firewalls, which containers can't reproduce
- Arch, Alpine, RHEL, Oracle Linux and CentOS Stream, and older systems with OpenVPN 2.4. The code supports them, but they have not had a tunnel test
