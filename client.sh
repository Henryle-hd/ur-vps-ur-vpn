#!/usr/bin/env bash
#
# ur-vpn client for macOS and Linux.
#
#     curl -fsSL https://raw.githubusercontent.com/Henryle-hd/ur-vps-ur-vpn/main/client.sh | bash
#
# Asks for the block your server printed, then installs OpenVPN, sets up a
# service that starts at boot, connects, and checks your traffic uses the VPN.
# You can also pass a file holding the block, or a plain .ovpn profile:
#
#     bash client.sh path/to/file
#
# Once installed, this same file is the `ur-vpn` command. Run `ur-vpn help`.
#
# Linux and macOS each implement the same set of functions, named linux_* and
# mac_*, and call_platform picks the right one.
#
# Must stay compatible with bash 3.2, the version macOS ships.

set -Eeuo pipefail

# --- Constants ----------------------------------------------------------------

UR_VPN_RAW=${UR_VPN_RAW:-https://raw.githubusercontent.com/Henryle-hd/ur-vps-ur-vpn/main}
UR_VPN_RELEASE_URL=${UR_VPN_RELEASE_URL:-https://github.com/Henryle-hd/ur-vps-ur-vpn/releases/latest/download}

# The release workflow stamps this. "dev" means installed from the main branch.
readonly UR_VPN_VERSION=dev

readonly BIN=/usr/local/bin/ur-vpn
readonly STATE_DIR=/etc/ur-vpn-client
readonly CONNECT_TIMEOUT=60

readonly LINUX_SERVICE=ur-vpn-client
readonly LINUX_CONF=/etc/openvpn/client/ur-vpn.conf
readonly LINUX_TUN=urvpn0

readonly MAC_CONF=$STATE_DIR/client.ovpn
readonly MAC_LOG=/var/log/ur-vpn.log
readonly MAC_LABEL=com.ur-vpn.client
readonly MAC_PLIST=/Library/LaunchDaemons/$MAC_LABEL.plist

PLATFORM=""
SUDO=""
PROFILE=""        # temp file holding the decoded profile
PASTED_BLOCK=""   # base64 read from the terminal
SAVED_TERMINAL="" # stty state to restore if interrupted during the paste
SUDO_KEEPALIVE=""
CONNECT_STARTED=""
UPDATE_DIR=""
TOP_DIR=""

# --- Output -------------------------------------------------------------------

if [[ -t 1 ]]; then
	BOLD=$'\033[1m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' RESET=$'\033[0m'
else
	BOLD="" GREEN="" YELLOW="" RED="" RESET=""
fi

step() { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() {
	printf '%sERROR:%s %s\n' "$RED" "$RESET" "$*" >&2
	exit 1
}

# --- Small helpers ------------------------------------------------------------

has() { command -v "$1" >/dev/null 2>&1; }

fetch() { curl -fsSL --retry 3 --max-time 120 "$1" -o "$2"; }

sha256_of() {
	if has sha256sum; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

call_platform() {
	local action=$1
	shift
	"${PLATFORM}_$action" "$@"
}

public_ip() { curl -4 -fsS --max-time "$1" https://api.ipify.org 2>/dev/null; }

restore_terminal() {
	if [[ -n $SAVED_TERMINAL ]]; then
		stty "$SAVED_TERMINAL" <"${UR_VPN_TTY:-/dev/tty}" 2>/dev/null || true
		SAVED_TERMINAL=""
	fi
}

cleanup() {
	restore_terminal
	if [[ -n $PROFILE ]]; then
		rm -f "$PROFILE"
	fi
	if [[ -n $UPDATE_DIR ]]; then
		rm -rf "$UPDATE_DIR"
	fi
	if [[ -n $TOP_DIR ]]; then
		rm -rf "$TOP_DIR"
	fi
	if [[ -n $SUDO_KEEPALIVE ]]; then
		kill "$SUDO_KEEPALIVE" 2>/dev/null || true
	fi
}

# ==============================================================================
#  The whole story
# ==============================================================================

cmd_setup() {
	get_profile "${1:-}"
	acquire_sudo
	call_platform setup
	wait_for_connection || explain_failure

	printf '\n\n%s%sConnected.%s The VPN also starts by itself at boot.\n' "$GREEN" "$BOLD" "$RESET"
	report_public_ip
	cat <<EOF

  ur-vpn stop     disconnect
  ur-vpn start    reconnect
  ur-vpn status   check the connection
  ur-vpn top      watch health and speed live
  ur-vpn remove   remove the VPN from this device
EOF
}

wait_for_connection() {
	local waited=0
	while ((waited < CONNECT_TIMEOUT)); do
		call_platform connected && return 0
		sleep 2
		waited=$((waited + 2))
		printf '.'
	done
	printf '\n'
	return 1
}

report_public_ip() {
	local address
	address=$(public_ip 10) || true
	if [[ -z $address ]]; then
		warn "connected, but the internet check through the VPN failed. See: ur-vpn logs"
	elif [[ $address == "$(profile_host)" ]]; then
		printf 'Your public IP is now %s%s%s, the VPN server.\n' "$BOLD" "$address" "$RESET"
	else
		printf 'Your public IP is now %s%s%s.\n' "$BOLD" "$address" "$RESET"
	fi
}

explain_failure() {
	printf '\n%sThe VPN is installed but did not connect within %s seconds.%s\n\n' "$RED" "$CONNECT_TIMEOUT" "$RESET" >&2
	call_platform logs 15 >&2 || true
	cat >&2 <<EOF

The usual cause is the provider's firewall blocking the VPN port. On your server,
allow inbound $(profile_port_and_proto) in the provider's web panel.
It keeps retrying by itself, so it will connect once the port is open.
Check with: ur-vpn status
EOF
	exit 1
}

# --- The profile --------------------------------------------------------------

# Leaves the profile in $PROFILE, from a file or from a paste.
get_profile() {
	local file=${1:-}
	PROFILE=$(mktemp)
	chmod 600 "$PROFILE"

	if [[ -z $file ]]; then
		read_pasted_block
		decode_block "$PASTED_BLOCK" >"$PROFILE" ||
			die "that block is damaged. Copy it again from the server (ur-vpn show NAME)."
	elif [[ ! -r $file ]]; then
		die "cannot read $file"
	elif grep -q 'BEGIN UR-VPN PROFILE' "$file"; then
		local block
		block=$(extract_block <"$file" 2>/dev/null) || die "$file has no complete BEGIN/END block"
		decode_block "$block" >"$PROFILE" || die "the block in $file is damaged"
	else
		cat "$file" >"$PROFILE"
	fi

	profile_looks_valid || die "that is not a valid VPN profile"
	step "Profile accepted for $(profile_remote)"
}

# Read from the terminal, not stdin: under `curl | bash` stdin is the script.
read_pasted_block() {
	local terminal=${UR_VPN_TTY:-/dev/tty}
	{ : <"$terminal"; } 2>/dev/null || die "no terminal to paste into. Pass the block as a file: bash client.sh FILE"

	printf '\n%sPaste the block from your server, then press Enter:%s\n' "$BOLD" "$RESET" >&2
	printf '(It is hidden while you paste because it contains your private key.)\n' >&2

	SAVED_TERMINAL=$(stty -g <"$terminal" 2>/dev/null || true)
	stty -echo <"$terminal" 2>/dev/null || true
	PASTED_BLOCK=$(extract_block <"$terminal") ||
		die "did not receive the END line. Copy the whole block, including BEGIN and END, and try again."
	restore_terminal
	printf '\n' >&2
}

# Turn text holding a BEGIN/END block into plain base64, printing a progress dot
# per line. Terminals and chat apps add stray spaces and carriage returns, so all
# whitespace is dropped first.
extract_block() {
	local line block="" inside=no
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line//[[:space:]]/}
		case $line in
		*BEGINUR-VPNPROFILE*)
			inside=yes
			block=""
			;;
		*ENDUR-VPNPROFILE*)
			[[ $inside == yes ]] || return 1
			printf '%s' "$block"
			return 0
			;;
		*)
			if [[ $inside == yes ]]; then
				block+=$line
				printf '.' >&2
			fi
			;;
		esac
	done
	return 1
}

decode_block() {
	# macOS spells it -D on older releases and -d on newer ones.
	{ base64 -d <<<"$1" 2>/dev/null || base64 -D <<<"$1" 2>/dev/null; } | gunzip -c 2>/dev/null
}

profile_looks_valid() {
	grep -q '^client' "$PROFILE" && grep -q '^remote ' "$PROFILE" &&
		grep -q '<ca>' "$PROFILE" && grep -q '<key>' "$PROFILE"
}

profile_remote() { awk '$1 == "remote" { print $2 ":" $3; exit }' "$PROFILE"; }
profile_host() { awk '$1 == "remote" { print $2; exit }' "$PROFILE"; }
profile_port_and_proto() { awk '$1 == "proto" { proto = $2 } $1 == "remote" { port = $3 } END { print port "/" proto }' "$PROFILE"; }

profile_dns() {
	local servers
	servers=$(sed -n 's/^# ur-vpn-dns: //p' "$PROFILE" | head -n 1)
	if [[ -z $servers ]]; then # a plain .ovpn from somewhere else
		servers=$(awk '$1 == "dhcp-option" && $2 == "DNS" { printf "%s ", $3 }' "$PROFILE")
	fi
	printf '%s' "${servers:-1.1.1.1 9.9.9.9}"
}

saved_dns() { cat "$STATE_DIR/dns" 2>/dev/null || printf '1.1.1.1 9.9.9.9'; }

# --- Administrator rights -----------------------------------------------------

use_root_if_needed() {
	if [[ $(id -u) -ne 0 ]]; then
		SUDO=sudo
	fi
}

acquire_sudo() {
	[[ -n $SUDO ]] || return 0
	has sudo || die "this needs root and sudo is not installed. Run it as root."
	printf 'Administrator access is needed.\n'
	sudo -v </dev/tty 2>/dev/null || sudo -v || die "could not get administrator access"
	# Slow installs, like Homebrew on a new Mac, can outlast the sudo timeout.
	(while sleep 50; do sudo -n true 2>/dev/null || exit 0; done) &
	SUDO_KEEPALIVE=$!
}

# Install this script as the ur-vpn command. Under `curl | bash` there is no file
# to copy, so download one.
install_command() {
	local script=${BASH_SOURCE[0]:-} download=""
	if [[ -z $script || ! -f $script ]]; then
		download=$(mktemp)
		if ! fetch "$UR_VPN_RAW/client.sh" "$download"; then
			rm -f "$download"
			warn "could not download the ur-vpn command; the VPN itself is unaffected"
			return 0
		fi
		script=$download
	fi
	$SUDO mkdir -p "$(dirname "$BIN")"
	$SUDO install -m 755 "$script" "$BIN"
	if [[ -n $download ]]; then
		rm -f "$download"
	fi
}

prepare_state_dir() {
	$SUDO mkdir -p "$STATE_DIR"
	$SUDO chmod 700 "$STATE_DIR"
	profile_dns | $SUDO tee "$STATE_DIR/dns" >/dev/null
}

# ==============================================================================
#  Linux
# ==============================================================================

linux_setup() {
	linux_install_openvpn
	linux_write_config
	install_command
	linux_write_service
	step "Connecting"
	CONNECT_STARTED=$(date '+%Y-%m-%d %H:%M:%S')
	# --no-block because a Type=notify unit would otherwise hang this script for
	# as long as the server is unreachable.
	$SUDO systemctl restart --no-block "$LINUX_SERVICE"
}

linux_install_openvpn() {
	has openvpn && return 0
	step "Installing OpenVPN"
	local manager
	manager=$(linux_package_manager) || die "no supported package manager found. Install OpenVPN yourself, then run this again."
	case $manager in
	apt-get)
		linux_apt update
		linux_apt install -y --no-install-recommends openvpn iproute2
		;;
	dnf | yum)
		linux_enable_epel "$manager"
		$SUDO "$manager" install -y -q openvpn iproute >/dev/null
		;;
	zypper) $SUDO zypper --non-interactive --quiet --gpg-auto-import-keys install --no-recommends openvpn iproute2 >/dev/null ;;
	pacman) $SUDO pacman -Syu --needed --noconfirm --quiet openvpn iproute2 >/dev/null ;;
	apk) $SUDO apk add --no-cache --quiet openvpn iproute2 >/dev/null ;;
	esac
	has openvpn || die "OpenVPN did not install"
}

linux_package_manager() {
	local manager
	for manager in apt-get dnf yum zypper pacman apk; do
		if has "$manager"; then
			printf '%s' "$manager"
			return 0
		fi
	done
	return 1
}

linux_apt() {
	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get -qq -o DPkg::Lock::Timeout=300 "$@" >/dev/null
}

linux_enable_epel() {
	local manager=$1 id major
	$SUDO "$manager" -q list available openvpn >/dev/null 2>&1 && return 0
	# shellcheck disable=SC1091
	read -r id major <<<"$(. /etc/os-release && printf '%s %s' "${ID:-}" "${VERSION_ID%%.*}")"
	case $id in
	fedora | amzn) ;;
	ol | oracle) $SUDO "$manager" install -y -q "oracle-epel-release-el$major" >/dev/null ;;
	rhel) $SUDO "$manager" install -y -q "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$major.noarch.rpm" >/dev/null ;;
	*) $SUDO "$manager" install -y -q epel-release >/dev/null ;;
	esac
}

linux_has_ipv6() {
	[[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] &&
		[[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 0 ]]
}

linux_write_config() {
	local config
	config=$(mktemp)
	{
		grep -v '^dev tun$' "$PROFILE"
		printf 'dev %s\ndev-type tun\n' "$LINUX_TUN"
		# OpenVPN treats a pushed IPv6 address as fatal if the kernel has IPv6 off.
		if ! linux_has_ipv6; then
			printf 'pull-filter ignore "ifconfig-ipv6"\npull-filter ignore "route-ipv6"\n'
		fi
	} >"$config"
	$SUDO mkdir -p "$(dirname "$LINUX_CONF")"
	$SUDO install -m 600 "$config" "$LINUX_CONF"
	rm -f "$config"
	prepare_state_dir
}

# DNS is set from ExecStartPost rather than an OpenVPN up script so it runs
# outside OpenVPN's SELinux/AppArmor confinement, on every distro alike.
# No Wants=network-online.target: it can stall the start for two minutes, and
# OpenVPN keeps retrying until the network is there.
linux_write_service() {
	has systemctl && [[ -d /run/systemd/system ]] ||
		die "this Linux client setup needs systemd. Your profile can be used directly with: sudo openvpn --config FILE"

	local type=simple unit
	if openvpn --version 2>/dev/null | grep -q 'enable_systemd=yes'; then
		type=notify
	fi
	unit=$(mktemp)
	cat >"$unit" <<EOF
[Unit]
Description=ur-vpn client
After=network-online.target

[Service]
Type=$type
WorkingDirectory=$(dirname "$LINUX_CONF")
ExecStart=$(command -v openvpn) --suppress-timestamps --config $LINUX_CONF
ExecStartPost=-$BIN dns-up
ExecStopPost=-$BIN dns-down
Restart=always
RestartSec=5
TimeoutStartSec=infinity
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
	$SUDO install -m 644 "$unit" "/etc/systemd/system/$LINUX_SERVICE.service"
	rm -f "$unit"
	$SUDO systemctl daemon-reload
	$SUDO systemctl enable "$LINUX_SERVICE" >/dev/null 2>&1
}

linux_tunnel_exists() { ip link show "$LINUX_TUN" >/dev/null 2>&1; }

linux_connected() {
	linux_tunnel_exists &&
		$SUDO journalctl -u "$LINUX_SERVICE" --since "$CONNECT_STARTED" --no-pager 2>/dev/null |
		grep -q 'Initialization Sequence Completed'
}

linux_is_up() { systemctl is-active --quiet "$LINUX_SERVICE" && linux_tunnel_exists; }

# Bytes received and sent by the tunnel. Prints nothing unless it is up.
linux_tunnel_bytes() {
	local stats=/sys/class/net/$LINUX_TUN/statistics
	linux_is_up || return 0
	printf '%s %s\n' "$(cat "$stats/rx_bytes")" "$(cat "$stats/tx_bytes")"
}

linux_ping_ms() { ping -n -c 1 -W 2 "$1" 2>/dev/null; }
linux_logs() { $SUDO journalctl -u "$LINUX_SERVICE" --no-pager -n "${1:-30}" 2>/dev/null || true; }
linux_on() { $SUDO systemctl enable --now --no-block "$LINUX_SERVICE" >/dev/null 2>&1; }
linux_off() { $SUDO systemctl disable --now "$LINUX_SERVICE" >/dev/null 2>&1 || true; }

linux_restart() {
	$SUDO systemctl enable "$LINUX_SERVICE" >/dev/null 2>&1
	$SUDO systemctl restart --no-block "$LINUX_SERVICE"
}

linux_remove() {
	linux_off
	$SUDO rm -f "/etc/systemd/system/$LINUX_SERVICE.service" "$LINUX_CONF"
	$SUDO systemctl daemon-reload
	$SUDO rm -rf "$STATE_DIR"
}

linux_nameserver_lines() {
	local server
	for server in $(saved_dns); do
		printf 'nameserver %s\n' "$server"
	done
}

linux_dns_up() {
	local waited
	for ((waited = 0; waited < 30; waited++)); do
		linux_tunnel_exists && break
		sleep 1
	done

	if has resolvectl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		# shellcheck disable=SC2046 # one argument per server
		resolvectl dns "$LINUX_TUN" $(saved_dns)
		resolvectl domain "$LINUX_TUN" '~.'
		resolvectl default-route "$LINUX_TUN" yes 2>/dev/null || true
		printf resolved >"$STATE_DIR/dns-method"
	elif has resolvconf && linux_nameserver_lines | resolvconf -a "$LINUX_TUN.ur-vpn"; then
		printf resolvconf >"$STATE_DIR/dns-method"
	else
		# Write through the file rather than replacing it: it may be a bind mount or symlink.
		[[ -f $STATE_DIR/resolv.conf.bak ]] || cat /etc/resolv.conf >"$STATE_DIR/resolv.conf.bak"
		linux_nameserver_lines >/etc/resolv.conf
		printf file >"$STATE_DIR/dns-method"
	fi
}

linux_dns_down() {
	case $(cat "$STATE_DIR/dns-method" 2>/dev/null || true) in
	resolved) resolvectl revert "$LINUX_TUN" 2>/dev/null || true ;;
	resolvconf) resolvconf -d "$LINUX_TUN.ur-vpn" 2>/dev/null || true ;;
	file)
		if [[ -f $STATE_DIR/resolv.conf.bak ]]; then
			cat "$STATE_DIR/resolv.conf.bak" >/etc/resolv.conf
			rm -f "$STATE_DIR/resolv.conf.bak"
		fi
		;;
	esac
	rm -f "$STATE_DIR/dns-method"
}

# ==============================================================================
#  macOS
# ==============================================================================

mac_setup() {
	mac_install_openvpn
	install_command
	mac_write_config
	mac_write_service
	step "Connecting"
	$SUDO rm -f "$MAC_LOG"
	mac_on
}

# Homebrew refuses to run as root, so drop back to the real user when needed.
as_login_user() {
	if [[ $(id -u) -ne 0 ]]; then
		"$@"
	elif [[ -n ${SUDO_USER:-} ]]; then
		sudo -u "$SUDO_USER" -H "$@"
	else
		die "Homebrew cannot run as root. Run this as your normal user, without sudo."
	fi
}

mac_brew() {
	local brew
	for brew in "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
		if [[ -n $brew && -x $brew ]]; then
			printf '%s' "$brew"
			return 0
		fi
	done
	return 1
}

mac_openvpn() {
	local brew prefix
	brew=$(mac_brew) || return 1
	prefix=$(as_login_user "$brew" --prefix)
	[[ -x $prefix/sbin/openvpn ]] || return 1
	printf '%s' "$prefix/sbin/openvpn"
}

mac_install_openvpn() {
	mac_openvpn >/dev/null 2>&1 && return 0
	if ! mac_brew >/dev/null; then
		step "Installing Homebrew (needed to get OpenVPN; can take several minutes on a new Mac)"
		as_login_user env NONINTERACTIVE=1 /bin/bash -c \
			"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" ||
			die "Homebrew did not install. See https://brew.sh, then run this again."
	fi
	step "Installing OpenVPN"
	as_login_user env HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "$(mac_brew)" install --quiet openvpn ||
		die "could not install OpenVPN with Homebrew"
	mac_openvpn >/dev/null || die "OpenVPN did not install"
}

mac_write_config() {
	local config
	config=$(mktemp)
	{
		cat "$PROFILE"
		printf 'script-security 2\n'
		printf 'up "%s dns-up"\n' "$BIN"
		printf 'down "%s dns-down"\n' "$BIN"
	} >"$config"
	prepare_state_dir
	$SUDO install -m 600 "$config" "$MAC_CONF"
	rm -f "$config"
}

mac_write_service() {
	local plist
	plist=$(mktemp)
	cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$MAC_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(mac_openvpn)</string>
		<string>--config</string><string>$MAC_CONF</string>
		<string>--log</string><string>$MAC_LOG</string>
	</array>
	<key>WorkingDirectory</key><string>$STATE_DIR</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
</dict>
</plist>
EOF
	$SUDO install -m 644 -o root -g wheel "$plist" "$MAC_PLIST"
	rm -f "$plist"
}

mac_connected() { $SUDO grep -q 'Initialization Sequence Completed' "$MAC_LOG" 2>/dev/null; }
mac_is_up() { $SUDO launchctl print "system/$MAC_LABEL" >/dev/null 2>&1 && mac_connected; }
mac_logs() { $SUDO tail -n "${1:-30}" "$MAC_LOG" 2>/dev/null || true; }
mac_off() { $SUDO launchctl bootout "system/$MAC_LABEL" 2>/dev/null || true; }

# Bytes received and sent by the tunnel. Prints nothing unless it is up. The last
# four netstat columns are stable: a tunnel leaves the Address column empty.
mac_tunnel_bytes() {
	local tunnel
	launchctl print "system/$MAC_LABEL" >/dev/null 2>&1 || return 0
	tunnel=$(route -n get 1.1.1.1 2>/dev/null | awk '$1 == "interface:" { print $2 }') || true
	case $tunnel in
	utun*) netstat -ibn -I "$tunnel" 2>/dev/null | awk '/<Link#/ { print $(NF - 4), $(NF - 1); exit }' ;;
	esac
}

mac_ping_ms() { ping -n -c 1 -t 2 "$1" 2>/dev/null; }

mac_on() {
	mac_off
	$SUDO launchctl bootstrap system "$MAC_PLIST"
}

mac_restart() { mac_on; }

mac_remove() {
	mac_off
	# OpenVPN's down hook restores DNS, but not if it was killed uncleanly.
	$SUDO "$BIN" dns-down 2>/dev/null || true
	$SUDO rm -f "$MAC_PLIST" "$MAC_LOG"
	$SUDO rm -rf "$STATE_DIR"
}

# Every enabled network service, one per line. The first line of the output is a
# note, and disabled services start with an asterisk.
mac_network_services() {
	/usr/sbin/networksetup -listallnetworkservices | sed '1d' | grep -v '^\*'
}

mac_refresh_dns() {
	/usr/bin/dscacheutil -flushcache 2>/dev/null || true
	/usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
}

# Runs as root from OpenVPN's up hook. Saves each service's DNS to restore later.
mac_dns_up() {
	local service current backup=$STATE_DIR/dns-backup
	: >"$backup.new"
	while IFS= read -r service; do
		[[ -n $service ]] || continue
		current=$(/usr/sbin/networksetup -getdnsservers "$service" 2>/dev/null | tr '\n' ' ')
		case $current in
		*"any DNS"*) current=Empty ;;
		esac
		printf '%s\t%s\n' "$service" "$current" >>"$backup.new"
		# shellcheck disable=SC2046 # one argument per server
		/usr/sbin/networksetup -setdnsservers "$service" $(saved_dns) 2>/dev/null || true
	done <<<"$(mac_network_services)"

	# A reconnect must not overwrite the real settings with the VPN's.
	if [[ -f $backup ]]; then
		rm -f "$backup.new"
	else
		mv "$backup.new" "$backup"
	fi
	mac_refresh_dns
}

mac_dns_down() {
	local service current backup=$STATE_DIR/dns-backup
	[[ -f $backup ]] || return 0
	while IFS=$'\t' read -r service current; do
		[[ -n $service ]] || continue
		# shellcheck disable=SC2086 # may be several servers
		/usr/sbin/networksetup -setdnsservers "$service" $current 2>/dev/null || true
	done <"$backup"
	rm -f "$backup"
	mac_refresh_dns
}

# ==============================================================================
#  The ur-vpn command
# ==============================================================================

cmd_on() {
	call_platform on
	printf 'VPN starting. Check with: ur-vpn status\n'
}

cmd_off() {
	call_platform off
	printf 'VPN off. It stays off until: ur-vpn start\n'
}

cmd_restart() {
	call_platform restart
	printf 'VPN restarting. Check with: ur-vpn status\n'
}

cmd_status() {
	if call_platform is_up; then
		printf 'VPN: connected\n'
	else
		printf 'VPN: not connected\n'
	fi
	printf 'Public IP: %s\n' "$(public_ip 8 || printf unknown)"
}

# --- The live view ------------------------------------------------------------

readonly TOP_PING_TARGET=1.1.1.1
readonly TOP_IP_EVERY=30

readonly AWK_HUMAN='
function human(n, units, i) {
	split("B KB MB GB TB", units, " ")
	n += 0
	i = 1
	while (n >= 1024 && i < 5) { n /= 1024; i++ }
	return sprintf(i == 1 ? "%d %s" : "%.1f %s", n, units[i])
}'

TOP_RX="" TOP_TX="" TOP_AT=0 TOP_RX_RATE=0 TOP_TX_RATE=0 TOP_TICKS=0
TOP_LATENCY="" TOP_SENT=0 TOP_LOST=0 TOP_MISSES=0 TOP_PUBLIC_IP="" TOP_SERVER=""

# Reads what the root-only profile says about the server, without asking for a
# password. Without sudo already cached, the view simply leaves this line out.
top_read_server() {
	local conf=$LINUX_CONF reader=cat
	if [[ $PLATFORM == mac ]]; then
		conf=$MAC_CONF
	fi
	if [[ -n $SUDO ]]; then
		reader="sudo -n cat"
	fi
	$reader "$conf" 2>/dev/null |
		awk '$1 == "proto" { proto = $2 } $1 == "remote" { host = $2; port = $3 } END { if (host != "") print host ":" port "/" proto }' || true
}

top_sample_tunnel() {
	local bytes rx tx now
	bytes=$(call_platform tunnel_bytes) || true
	now=$(date +%s)
	if [[ -z $bytes ]]; then
		TOP_RX="" TOP_TX="" TOP_RX_RATE=0 TOP_TX_RATE=0
		return 0
	fi
	rx=${bytes%% *}
	tx=${bytes##* }
	if [[ -n $TOP_RX ]] && ((now > TOP_AT && rx >= TOP_RX && tx >= TOP_TX)); then
		TOP_RX_RATE=$(((rx - TOP_RX) / (now - TOP_AT)))
		TOP_TX_RATE=$(((tx - TOP_TX) / (now - TOP_AT)))
	fi
	TOP_RX=$rx TOP_TX=$tx TOP_AT=$now
}

# Prints the round trip in ms, or nothing if there was no reply. An outside address
# tests the whole path, through the server and out to the internet.
top_ping() {
	call_platform ping_ms "$TOP_PING_TARGET" | sed -n 's/.*time[=<]\([0-9.]*\).*/\1/p' | head -n 1
}

# These two run in the background so a slow network never freezes the screen. Each
# writes to its own file, which top_collect picks up on a later tick.
top_start_ping() {
	if has ping; then
		(top_ping >"$TOP_DIR/ping.new" 2>/dev/null; mv -f "$TOP_DIR/ping.new" "$TOP_DIR/ping" 2>/dev/null) &
	fi
}

top_start_ip_check() {
	(public_ip 5 >"$TOP_DIR/ip.new" 2>/dev/null; mv -f "$TOP_DIR/ip.new" "$TOP_DIR/ip" 2>/dev/null) &
}

top_collect() {
	if [[ -f $TOP_DIR/ping ]]; then
		top_record_ping "$(cat "$TOP_DIR/ping")"
		rm -f "$TOP_DIR/ping"
		top_start_ping
	fi
	if [[ -f $TOP_DIR/ip ]]; then
		TOP_PUBLIC_IP=$(cat "$TOP_DIR/ip")
		rm -f "$TOP_DIR/ip"
	fi
	if ((TOP_TICKS % TOP_IP_EVERY == 0)); then
		top_start_ip_check
	fi
	TOP_TICKS=$((TOP_TICKS + 1))
}

# Halving keeps the loss figure about the last minute, not the whole session.
top_record_ping() {
	TOP_LATENCY=$1
	TOP_SENT=$((TOP_SENT + 1))
	if [[ -z $1 ]]; then
		TOP_LOST=$((TOP_LOST + 1))
		TOP_MISSES=$((TOP_MISSES + 1))
	else
		TOP_MISSES=0
	fi
	if ((TOP_SENT >= 40)); then
		TOP_SENT=$((TOP_SENT / 2)) TOP_LOST=$((TOP_LOST / 2))
	fi
}

top_loss_percent() {
	if ((TOP_SENT > 0)); then
		printf '%s' $((TOP_LOST * 100 / TOP_SENT))
	else
		printf 0
	fi
}

# Networks drop the odd packet, so one lost ping means nothing: it takes several
# in a row to say the internet is gone, and a few pings to judge the loss.
top_health() {
	local latency=${TOP_LATENCY%%.*}
	if [[ -z $TOP_RX ]]; then
		printf '%snot connected%s  Connect with: ur-vpn start' "$RED" "$RESET"
	elif ((TOP_SENT == 0)); then
		printf '%schecking%s' "$YELLOW" "$RESET"
	elif ((TOP_MISSES >= 3)); then
		printf '%sno internet%s  the VPN is up, but pings through it get no reply' "$RED" "$RESET"
	elif ((${latency:-0} >= 300 || (TOP_SENT >= 5 && $(top_loss_percent) >= 10))); then
		printf '%sslow%s' "$YELLOW" "$RESET"
	else
		printf '%sgood%s' "$GREEN" "$RESET"
	fi
}

top_frame() {
	printf '%sur-vpn top%s  %s   %s   press q to quit\n\n' "$BOLD" "$RESET" "$UR_VPN_VERSION" "$(date +%H:%M:%S)"
	printf 'Health     %s\n' "$(top_health)"
	if [[ -z $TOP_RX ]]; then
		return 0
	fi
	printf 'VPN        connected\n'
	if [[ -n $TOP_SERVER ]]; then
		printf 'Server     %s\n' "$TOP_SERVER"
	fi
	printf 'Public IP  %s\n' "${TOP_PUBLIC_IP:-checking}"
	if ! has ping; then
		printf 'Latency    needs the ping command\n'
	elif [[ -n $TOP_LATENCY ]]; then
		printf 'Latency    %s ms   loss %s%%\n' "$TOP_LATENCY" "$(top_loss_percent)"
	else
		printf 'Latency    no reply   loss %s%%\n' "$(top_loss_percent)"
	fi
	RX=$TOP_RX TX=$TOP_TX RX_RATE=$TOP_RX_RATE TX_RATE=$TOP_TX_RATE awk "$AWK_HUMAN"'
		BEGIN {
			printf "Speed      down %-12s up %s\n", human(ENVIRON["RX_RATE"]) "/s", human(ENVIRON["TX_RATE"]) "/s"
			printf "Total      down %-12s up %s\n", human(ENVIRON["RX"]), human(ENVIRON["TX"])
		}'
}

top_ping_until_reply() {
	local _
	has ping || return 0
	for _ in 1 2 3; do
		top_record_ping "$(top_ping)"
		if [[ -n $TOP_LATENCY ]]; then
			return 0
		fi
	done
}

cmd_top() {
	TOP_DIR=$(mktemp -d)
	TOP_SERVER=$(top_read_server)
	top_sample_tunnel
	if [[ ${1:-} == --once || ! -t 0 || ! -t 1 ]]; then
		sleep 1
		top_sample_tunnel
		top_ping_until_reply
		TOP_PUBLIC_IP=$(public_ip 5) || true
		top_frame
		return 0
	fi

	trap 'printf "\033[?7h\033[?25h\033[?1049l"; cleanup' EXIT
	trap 'exit 0' INT TERM
	printf '\033[?1049h\033[?25l\033[?7l' # own screen, no cursor, no line wrapping
	top_start_ping
	local key="" rows
	while [[ $key != [qQ] ]]; do
		top_collect
		rows=$(stty size 2>/dev/null | cut -d' ' -f1) || true
		if [[ ${rows:-0} -le 0 ]]; then
			rows=24
		fi
		printf '\033[2J\033[H%s' "$(top_frame | awk -v rows="$rows" 'NR <= rows')"
		key=""
		read -rsn1 -t 1 key || true
		top_sample_tunnel
	done
}

# Only the command changes: the VPN stays as it is, connected or off.
cmd_update() {
	[[ -f $BIN ]] || die "ur-vpn is not installed on this device"
	UPDATE_DIR=$(mktemp -d)
	local new=$UPDATE_DIR/client.sh sums=$UPDATE_DIR/SHA256SUMS expected version

	step "Checking for a new release"
	fetch "$UR_VPN_RELEASE_URL/client.sh" "$new" || die "could not download the latest release from $UR_VPN_RELEASE_URL"
	fetch "$UR_VPN_RELEASE_URL/SHA256SUMS" "$sums" || die "could not download the checksums from $UR_VPN_RELEASE_URL"

	expected=$(awk '$2 == "client.sh" { print $1 }' "$sums")
	[[ -n $expected && $expected == "$(sha256_of "$new")" ]] || die "the download failed its checksum. Nothing was changed."
	bash -n "$new" || die "the download is not a valid script. Nothing was changed."
	version=$(sed -n 's/^readonly UR_VPN_VERSION=//p' "$new")
	[[ -n $version ]] || die "the download has no version. Nothing was changed."
	if [[ $version == "$UR_VPN_VERSION" ]]; then
		printf 'Already on the latest release, %s.\n' "$UR_VPN_VERSION"
		return 0
	fi

	acquire_sudo
	$SUDO install -m 755 "$new" "$BIN.new"
	$SUDO mv -f "$BIN.new" "$BIN"
	printf 'Updated from %s to %s.\n' "$UR_VPN_VERSION" "$version"
}

cmd_remove() {
	call_platform remove
	$SUDO rm -f "$BIN"
	printf 'Removed from this device. The openvpn package itself was left installed.\n'
}

usage() {
	cat <<EOF
ur-vpn client

  client.sh [FILE]   set up the VPN; FILE holds the server's block or an .ovpn profile
  ur-vpn start       connect, and start at boot  (or: on)
  ur-vpn stop        disconnect, and stay off    (or: off)
  ur-vpn restart     reconnect
  ur-vpn status      show the connection state
  ur-vpn top         live health, latency and speed  (q to quit, --once to print once)
  ur-vpn logs [N]    show recent log lines
  ur-vpn update      move to the latest release
  ur-vpn version     print the installed version
  ur-vpn remove      remove the VPN from this device
EOF
}

detect_platform() {
	case $(uname -s) in
	Darwin) PLATFORM=mac ;;
	Linux) PLATFORM=linux ;;
	*) die "unsupported system: $(uname -s). On Windows, use client.ps1." ;;
	esac
}

main() {
	trap cleanup EXIT
	detect_platform
	use_root_if_needed
	case ${1:-} in
	-h | --help | help) usage ;;
	start | on) cmd_on ;;
	stop | off) cmd_off ;;
	restart) cmd_restart ;;
	status) cmd_status ;;
	top) cmd_top "${2:-}" ;;
	logs) call_platform logs "${2:-30}" ;;
	update) cmd_update ;;
	version) printf '%s\n' "$UR_VPN_VERSION" ;;
	remove | uninstall) cmd_remove ;;
	dns-up) call_platform dns_up ;;
	dns-down) call_platform dns_down ;;
	*) cmd_setup "${1:-}" ;;
	esac
}

if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then
	main "$@"
fi
