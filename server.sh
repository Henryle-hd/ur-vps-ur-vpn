#!/usr/bin/env bash
#
# ur-vpn server: your own OpenVPN on any mainstream Linux VPS, in one command.
#
#     curl -fsSL https://raw.githubusercontent.com/Henryle-hd/ur-vps-ur-vpn/main/server.sh | sudo bash
#
# Nothing to answer. To change a default, set it in the environment:
#
#     VPN_HOST     address clients connect to    detected public IP
#     VPN_PROTO    udp or tcp                    udp
#     VPN_PORT     port to listen on             1194, or the next free port
#     VPN_DNS      DNS servers for clients       1.1.1.1 9.9.9.9
#     VPN_CLIENT   name of the first client      client1
#
# Once installed, this same file is the `ur-vpn` command. Run `ur-vpn help`.
#
# Everything is inside functions and main runs on the very last line, so a
# cut-off download can't run half a script.

set -Eeuo pipefail

# --- Constants ----------------------------------------------------------------

UR_VPN_RAW=${UR_VPN_RAW:-https://raw.githubusercontent.com/Henryle-hd/ur-vps-ur-vpn/main}
UR_VPN_RELEASE_URL=${UR_VPN_RELEASE_URL:-https://github.com/Henryle-hd/ur-vps-ur-vpn/releases/latest/download}

# The release workflow stamps this. "dev" means installed from the main branch.
readonly VERSION=dev

readonly EASYRSA_VERSION=3.2.7
readonly EASYRSA_SHA256=308743bc9fe871b902d47dbe98d749daff3a05b27531684f02625ce7208d4598

readonly STATE_DIR=/etc/ur-vpn
readonly SETTINGS=$STATE_DIR/settings.env
readonly INSTALLED_MARK=$STATE_DIR/.installed
readonly PKI_DIR=$STATE_DIR/easy-rsa
readonly CLIENTS_DIR=$STATE_DIR/clients

# What the running server reads. The CA key is never copied here.
readonly OVPN_DIR=/etc/openvpn/server/ur-vpn
readonly TUN_DEV=urvpn0
readonly SERVICE=ur-vpn-server
readonly STATUS_FILE=/run/openvpn-server/status-ur-vpn.log

readonly BIN=/usr/local/bin/ur-vpn
readonly LOG=/var/log/ur-vpn-install.log
readonly SYSCTL_FILE=/etc/sysctl.d/99-ur-vpn.conf
readonly TEMP_SELF_PREFIX=/tmp/ur-vpn-self.

# Filled in by detect_system.
PACKAGE_MANAGER=""
INIT_SYSTEM=""
OS_ID=""
OS_MAJOR=""
SELF=""
UPDATE_DIR=""

# --- Output -------------------------------------------------------------------

if [[ -t 1 ]]; then
	BOLD=$'\e[1m' GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m' CYAN=$'\e[36m' RESET=$'\e[0m'
else
	BOLD="" GREEN="" YELLOW="" RED="" CYAN="" RESET=""
fi

step() { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
error() { printf '%sERROR:%s %s\n' "$RED" "$RESET" "$*" >&2; }
die() {
	error "$*"
	exit 1
}

# Run a command with its output in the install log, showing it only on failure.
quiet() {
	"$@" >>"$LOG" 2>&1 && return 0
	error "command failed: $*"
	tail -n 25 "$LOG" >&2 || true
	printf 'Full log: %s\n' "$LOG" >&2
	exit 1
}

on_unexpected_error() {
	local code=$? line=$1
	error "setup stopped at line $line (exit $code). It is safe to run the script again."
	if [[ -f $LOG ]]; then
		printf 'Log: %s\n' "$LOG" >&2
	fi
	exit "$code"
}

# --- Small helpers ------------------------------------------------------------

has() { command -v "$1" >/dev/null 2>&1; }

wait_until() {
	local seconds=$1 waited
	shift
	for ((waited = 0; waited < seconds; waited++)); do
		"$@" && return 0
		sleep 1
	done
	return 1
}

# Print the word after KEY: `ip route get 1.1.1.1 | word_after dev` prints eth0.
word_after() {
	awk -v key="$1" '{ for (i = 1; i < NF; i++) if ($i == key) { print $(i + 1); exit } }'
}

is_ipv4() {
	local address=$1 octet
	[[ $address =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
	local IFS=.
	for octet in $address; do
		((10#$octet <= 255)) || return 1
	done
}

selinux_enforcing() { has getenforce && [[ $(getenforce 2>/dev/null) == Enforcing ]]; }
firewalld_running() { has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; }

# ==============================================================================
#  The whole story
# ==============================================================================

cmd_install() {
	if [[ -f $INSTALLED_MARK ]]; then
		show_existing_install
		return 0
	fi

	: >"$LOG"
	chmod 600 "$LOG"
	local client=${VPN_CLIENT:-client1}
	is_valid_name "$client" || die "VPN_CLIENT must be 1-32 letters, numbers, - or _"

	check_tun
	install_packages
	check_tun # the packages may have pulled in a new kernel
	prepare_settings
	load_settings
	setup_pki
	write_server_config
	install -m 755 "$SELF" "$BIN" # the service's firewall hooks call this copy
	enable_forwarding
	open_firewall
	write_service
	start_service
	verify_server
	create_first_client "$client"
	: >"$INSTALLED_MARK"
	print_finish "$client"
}

show_existing_install() {
	load_settings
	local first
	first=$(find "$CLIENTS_DIR" -maxdepth 1 -name '*.ovpn' -exec basename {} .ovpn \; | sort | head -n 1)
	printf 'ur-vpn is already installed, so nothing was changed.\n\n'
	cmd_status
	printf '\n'
	if [[ -n $first ]]; then
		print_client_steps "$first"
	fi
}

create_first_client() {
	[[ ! -f $CLIENTS_DIR/$1.ovpn ]] || return 0
	step "Creating the first client: $1"
	build_profile "$1"
}

# --- Getting started: where are we running? -----------------------------------

# Under `curl | bash` there is no file to copy to /usr/local/bin, so fetch one.
# Then restart under sudo if we are not root.
bootstrap() {
	SELF=${BASH_SOURCE[0]:-}
	if [[ -z $SELF || ! -f $SELF ]]; then
		SELF=$(mktemp "${TEMP_SELF_PREFIX}XXXXXX")
		fetch "$UR_VPN_RAW/server.sh" "$SELF" || die "could not download $UR_VPN_RAW/server.sh"
	fi
	if [[ $(id -u) -ne 0 ]]; then
		has sudo || die "run this as root (sudo is not installed)"
		exec sudo env \
			VPN_HOST="${VPN_HOST:-}" VPN_PORT="${VPN_PORT:-}" VPN_PROTO="${VPN_PROTO:-}" \
			VPN_DNS="${VPN_DNS:-}" VPN_CLIENT="${VPN_CLIENT:-}" UR_VPN_RAW="$UR_VPN_RAW" \
			UR_VPN_RELEASE_URL="$UR_VPN_RELEASE_URL" \
			bash "$SELF" "$@"
	fi
}

fetch() {
	if has curl; then
		curl -fsSL --retry 3 --max-time 120 "$1" -o "$2"
	elif has wget; then
		wget -q -O "$2" "$1"
	else
		return 127
	fi
}

remove_temp_files() {
	case $SELF in
	"$TEMP_SELF_PREFIX"*) rm -f "$SELF" ;;
	esac
	if [[ -n $UPDATE_DIR ]]; then
		rm -rf "$UPDATE_DIR"
	fi
}

detect_system() {
	[[ $(uname -s) == Linux ]] || die "server.sh runs on the Linux VPS. For this machine use client.sh or client.ps1."

	if [[ -r /etc/os-release ]]; then
		local version
		# shellcheck disable=SC1091
		read -r OS_ID version <<<"$(. /etc/os-release && printf '%s %s' "${ID:-unknown}" "${VERSION_ID:-0}")"
		OS_MAJOR=${version%%.*}
	fi

	local candidate
	for candidate in apt-get dnf yum zypper pacman apk; do
		if has "$candidate"; then
			PACKAGE_MANAGER=$candidate
			break
		fi
	done
	[[ -n $PACKAGE_MANAGER ]] || die "no supported package manager found (apt, dnf, yum, zypper, pacman, apk)"

	if [[ -d /run/systemd/system ]]; then
		INIT_SYSTEM=systemd
	elif has rc-service; then
		INIT_SYSTEM=openrc
	else
		die "needs systemd or OpenRC to keep the VPN running across reboots"
	fi
}

# OpenVZ/LXC plans often have no TUN device until it is enabled in the panel.
check_tun() {
	modprobe tun >/dev/null 2>&1 || true
	if [[ ! -e /dev/net/tun ]]; then
		mkdir -p /dev/net
		mknod /dev/net/tun c 10 200 2>/dev/null || true
		chmod 600 /dev/net/tun 2>/dev/null || true
	fi
	(exec 7<>/dev/net/tun) 2>/dev/null ||
		die "the TUN device is not available. On OpenVZ/LXC plans, enable 'TUN/TAP' in your VPS control panel, reboot, and run this again. If a kernel update was just installed, reboot first."
}

# --- Chapter 1: packages ------------------------------------------------------

install_packages() {
	step "Installing OpenVPN and dependencies with $PACKAGE_MANAGER"
	local packages=(openvpn openssl iptables ca-certificates tar gzip)
	has curl || packages+=(curl) # asking for it on RHEL-family systems conflicts with curl-minimal

	case $PACKAGE_MANAGER in
	apt-get)
		export DEBIAN_FRONTEND=noninteractive
		# A freshly booted VPS is often still holding the dpkg lock for
		# unattended-upgrades, so wait for it rather than failing.
		local apt=(apt-get -o DPkg::Lock::Timeout=300)
		quiet "${apt[@]}" update
		quiet "${apt[@]}" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
			install -y --no-install-recommends "${packages[@]}" iproute2 procps
		;;
	dnf | yum)
		enable_epel
		if selinux_enforcing; then
			packages+=(policycoreutils-python-utils)
		fi
		quiet "$PACKAGE_MANAGER" install -y "${packages[@]}" iproute procps-ng
		;;
	zypper)
		quiet zypper --non-interactive --gpg-auto-import-keys install --no-recommends \
			"${packages[@]}" iproute2 procps
		;;
	pacman)
		# Arch does not support partial upgrades, so -Syu is required here.
		quiet pacman -Syu --needed --noconfirm "${packages[@]}" iproute2 procps-ng
		;;
	apk)
		quiet apk add --no-cache "${packages[@]}" ip6tables iproute2 coreutils
		;;
	esac
	has openvpn || die "OpenVPN did not install"
}

enable_epel() {
	case $OS_ID in
	amzn | fedora) return 0 ;;
	esac
	"$PACKAGE_MANAGER" -q list available openvpn >/dev/null 2>&1 && return 0

	step "Enabling EPEL"
	case $OS_ID in
	ol | oracle) quiet "$PACKAGE_MANAGER" install -y "oracle-epel-release-el$OS_MAJOR" ;;
	rhel) quiet "$PACKAGE_MANAGER" install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$OS_MAJOR.noarch.rpm" ;;
	*) quiet "$PACKAGE_MANAGER" install -y epel-release ;;
	esac
}

# --- Chapter 2: settings ------------------------------------------------------

load_settings() {
	[[ -r $SETTINGS ]] || die "ur-vpn is not installed on this machine"
	# shellcheck disable=SC1090
	. "$SETTINGS"
}

prepare_settings() {
	if [[ -f $SETTINGS ]]; then
		# An earlier attempt stopped partway. Keep its choices and certificates.
		stop_service_if_running
		return 0
	fi
	step "Detecting network settings"

	NIC=$(default_interface)
	[[ -n $NIC ]] || die "no default IPv4 route found. An IPv4 connection is required."

	PROTO=${VPN_PROTO:-udp}
	[[ $PROTO == udp || $PROTO == tcp ]] || die "VPN_PROTO must be udp or tcp"

	PORT=$(choose_port "$PROTO")
	NET_BASE=$(choose_subnet)
	HOST=$(choose_host)
	DNS_SERVERS=$(choose_dns)
	NET6=$(random_ula)
	SERVER_CN=server_$(openssl rand -hex 8)

	IPV6_EGRESS=no
	if has_ipv6_egress; then IPV6_EGRESS=yes; fi

	TLS_MODE=v2
	if openvpn_is_legacy; then TLS_MODE=legacy; fi

	install -d -m 700 "$STATE_DIR"
	local name
	for name in NIC PROTO PORT NET_BASE HOST DNS_SERVERS NET6 SERVER_CN IPV6_EGRESS TLS_MODE; do
		printf '%s=%q\n' "$name" "${!name}"
	done >"$SETTINGS"
	chmod 600 "$SETTINGS"
}

default_interface() {
	local nic
	nic=$(ip -4 route get 1.1.1.1 2>/dev/null | word_after dev) || true
	if [[ -z $nic ]]; then
		nic=$(ip -4 route show default 2>/dev/null | word_after dev) || true
	fi
	printf '%s' "$nic"
}

port_in_use() {
	local proto=$1 port=$2 flag=-lnt
	[[ $proto == udp ]] && flag=-lnu
	ss "$flag" 2>/dev/null | awk '{ print $4 }' | grep -Eq "[:.]$port\$"
}

choose_port() {
	local proto=$1 port
	if [[ -n ${VPN_PORT:-} ]]; then
		[[ $VPN_PORT =~ ^[0-9]+$ ]] && ((VPN_PORT >= 1 && VPN_PORT <= 65535)) || die "VPN_PORT must be 1-65535"
		port_in_use "$proto" "$VPN_PORT" && die "port $VPN_PORT/$proto is already in use"
		printf '%s' "$VPN_PORT"
		return 0
	fi
	for port in 1194 1195 1196 1197 1198 51194 51195; do
		if ! port_in_use "$proto" "$port"; then
			printf '%s' "$port"
			return 0
		fi
	done
	die "no free port found; set VPN_PORT"
}

# The way packets to ADDRESS leave this machine: "gateway|interface".
route_path() {
	local route
	route=$(ip -4 route get "$1" 2>/dev/null) || true
	printf '%s|%s' "$(word_after via <<<"$route")" "$(word_after dev <<<"$route")"
}

# A subnet nothing here uses takes the same path as the internet. Any other path
# means a private network the VPS can already reach, which the VPN must not hide.
choose_subnet() {
	local base internet_path
	internet_path=$(route_path 1.1.1.1)
	for base in 10.8 10.9 10.10 10.11 10.12 10.13 10.14 10.15 172.27 172.28 172.29; do
		if [[ $(route_path "$base.0.1") == "$internet_path" ]]; then
			printf '%s' "$base"
			return 0
		fi
	done
	die "every candidate VPN subnet overlaps an existing network"
}

choose_host() {
	local host
	if [[ -n ${VPN_HOST:-} ]]; then
		[[ $VPN_HOST =~ ^[A-Za-z0-9.-]+$ ]] || die "VPN_HOST must be an IPv4 address or hostname"
		printf '%s' "$VPN_HOST"
	elif host=$(detect_public_ip); then
		printf '%s' "$host"
	else
		host=$(ip -4 route get 1.1.1.1 | word_after src)
		warn "could not look up the public IP, using $host. If that is wrong, set VPN_HOST, run ur-vpn uninstall, and run this script again."
		printf '%s' "$host"
	fi
}

detect_public_ip() {
	local url address
	for url in https://api.ipify.org https://ipv4.icanhazip.com https://checkip.amazonaws.com https://ifconfig.me/ip; do
		address=$(curl -4 -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]') || continue
		if is_ipv4 "$address"; then
			printf '%s' "$address"
			return 0
		fi
	done
	return 1
}

choose_dns() {
	local servers server
	servers=$(printf '%s' "${VPN_DNS:-1.1.1.1 9.9.9.9}" | tr ',' ' ')
	for server in $servers; do
		is_ipv4 "$server" || die "VPN_DNS has an invalid IPv4 address: $server"
	done
	printf '%s' "$servers"
}

has_ipv6_egress() {
	[[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] || return 1
	[[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 0 ]] || return 1
	[[ -n $(ip -6 route show default 2>/dev/null) ]] || return 1
	[[ -n $(ip -6 addr show scope global 2>/dev/null) ]]
}

# A random private IPv6 /48 (RFC 4193), of which the VPN uses one /64.
random_ula() {
	local hex
	hex=$(openssl rand -hex 5)
	printf 'fd%s:%s:%s::' "${hex:0:2}" "${hex:2:4}" "${hex:6:4}"
}

# OpenVPN 2.4 has no data-ciphers and no tls-crypt-v2.
openvpn_is_legacy() {
	local version major minor
	version=$(openvpn --version 2>/dev/null | awk 'NR == 1 { print $2 }')
	major=${version%%.*}
	minor=${version#*.}
	minor=${minor%%.*}
	[[ ${major:-0} -eq 2 && ${minor:-0} -lt 5 ]]
}

# --- Chapter 3: certificates --------------------------------------------------

easyrsa() {
	(
		cd "$PKI_DIR"
		export EASYRSA_BATCH=1 EASYRSA_ALGO=ec EASYRSA_CURVE=prime256v1 EASYRSA_DIGEST=sha256
		export EASYRSA_CA_EXPIRE=3650 EASYRSA_CERT_EXPIRE=3650
		# The default CRL lifetime is 180 days. When a CRL expires the server
		# rejects every client, so make it last as long as the CA.
		export EASYRSA_CRL_DAYS=3650
		./easyrsa "$@"
	)
}

download_easyrsa() {
	[[ ! -x $PKI_DIR/easyrsa ]] || return 0
	local archive
	archive=$(mktemp)
	quiet curl -fsSL --retry 3 --max-time 120 -o "$archive" \
		"https://github.com/OpenVPN/easy-rsa/releases/download/v$EASYRSA_VERSION/EasyRSA-$EASYRSA_VERSION.tgz"
	printf '%s  %s\n' "$EASYRSA_SHA256" "$archive" | sha256sum -c - >/dev/null 2>&1 ||
		die "Easy-RSA download failed its SHA-256 check"
	install -d -m 700 "$PKI_DIR"
	tar xzf "$archive" --strip-components=1 --no-same-owner -C "$PKI_DIR"
	rm -f "$archive"
}

setup_pki() {
	step "Creating the certificate authority and server certificate"
	install -d -m 700 "$STATE_DIR" "$CLIENTS_DIR"
	download_easyrsa

	if [[ ! -f $PKI_DIR/pki/ca.crt ]]; then
		if [[ ! -d $PKI_DIR/pki ]]; then
			quiet easyrsa init-pki
		fi
		EASYRSA_REQ_CN="ur-vpn CA" quiet easyrsa build-ca nopass
	fi
	if [[ ! -f $PKI_DIR/pki/issued/$SERVER_CN.crt ]]; then
		quiet easyrsa build-server-full "$SERVER_CN" nopass
	fi
	quiet easyrsa gen-crl

	# OpenVPN drops to nobody and re-reads the CRL for each connection, so the
	# package-owned parent directories must allow traversal.
	install -d -m 711 "$OVPN_DIR"
	chmod o+x /etc/openvpn /etc/openvpn/server
	install -m 644 "$PKI_DIR/pki/ca.crt" "$OVPN_DIR/ca.crt"
	install -m 644 "$PKI_DIR/pki/crl.pem" "$OVPN_DIR/crl.pem"
	install -m 644 "$PKI_DIR/pki/issued/$SERVER_CN.crt" "$OVPN_DIR/server.crt"
	install -m 600 "$PKI_DIR/pki/private/$SERVER_CN.key" "$OVPN_DIR/server.key"

	if [[ $TLS_MODE == v2 ]]; then
		[[ -f $OVPN_DIR/tc-v2.key ]] || quiet openvpn --genkey tls-crypt-v2-server "$OVPN_DIR/tc-v2.key"
		chmod 600 "$OVPN_DIR/tc-v2.key"
	else
		[[ -f $OVPN_DIR/tc.key ]] || quiet openvpn --genkey --secret "$OVPN_DIR/tc.key"
		chmod 600 "$OVPN_DIR/tc.key"
	fi
}

# --- Chapter 4: server configuration ------------------------------------------

write_server_config() {
	step "Writing the OpenVPN server configuration"
	cat >"$OVPN_DIR/server.conf" <<EOF
# Generated by ur-vpn.

# Network
port $PORT
proto $PROTO
dev $TUN_DEV
dev-type tun
topology subnet
server $NET_BASE.0.0 255.255.255.0
keepalive 10 120
$(exit_notify_config)

# Send all client traffic and DNS through the tunnel
push "redirect-gateway def1 ipv6 bypass-dhcp"
$(ipv6_config)
$(dns_config)
push "block-outside-dns"

# Identity
ca ca.crt
cert server.crt
key server.key
dh none
crl-verify crl.pem
remote-cert-tls client

# Encryption
tls-version-min 1.2
auth SHA256
$(tls_config)

# Run with as few rights as possible
user nobody
group $(nobody_group)
persist-key
persist-tun
verb 3
EOF
	chmod 600 "$OVPN_DIR/server.conf"
}

exit_notify_config() {
	if [[ $PROTO == udp ]]; then
		printf 'explicit-exit-notify 1'
	fi
}

# Clients' IPv6 goes through the tunnel too, or it would leak around the VPN on
# dual-stack networks. If the server has no IPv6 route out, the setup from the
# OpenVPN manual is a placeholder address plus block-ipv6: IPv6 fails fast and
# applications fall back to IPv4.
ipv6_config() {
	if [[ $IPV6_EGRESS == yes ]]; then
		printf 'server-ipv6 %s/64' "$NET6"
	else
		printf 'push "ifconfig-ipv6 %s2/64 %s1"\nblock-ipv6' "$NET6" "$NET6"
	fi
}

dns_config() {
	local server
	for server in $DNS_SERVERS; do
		printf 'push "dhcp-option DNS %s"\n' "$server"
	done
}

tls_config() {
	if [[ $TLS_MODE == v2 ]]; then
		printf 'tls-crypt-v2 tc-v2.key\ndata-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305'
	else
		printf 'tls-crypt tc.key\ncipher AES-256-GCM\nncp-ciphers AES-256-GCM:AES-128-GCM'
	fi
}

nobody_group() {
	if getent group nogroup >/dev/null 2>&1; then
		printf nogroup
	else
		printf nobody
	fi
}

# --- Chapter 5: forwarding and firewall ---------------------------------------

enable_forwarding() {
	step "Enabling IP forwarding"
	mkdir -p "${SYSCTL_FILE%/*}"
	{
		printf 'net.ipv4.ip_forward = 1\n'
		if [[ $IPV6_EGRESS == yes ]]; then
			printf 'net.ipv6.conf.all.forwarding = 1\n'
			# Forwarding makes Linux ignore router advertisements unless accept_ra
			# is 2, which would drop the VPS's own IPv6 on SLAAC networks.
			printf 'net.ipv6.conf.%s.accept_ra = 2\n' "$NIC"
		fi
	} >"$SYSCTL_FILE"
	chmod 644 "$SYSCTL_FILE"
	sysctl -p "$SYSCTL_FILE" >>"$LOG" 2>&1 || true
	[[ $(cat /proc/sys/net/ipv4/ip_forward) == 1 ]] || die "could not enable net.ipv4.ip_forward"
	if [[ -d /etc/runlevels/boot ]]; then
		rc-update add sysctl boot >/dev/null 2>&1 || true
	fi
}

# Only rules are ever added. Default policies and SSH access are left alone, so
# this cannot lock you out of the VPS.
firewall_backend() {
	if firewalld_running; then
		printf firewalld
	elif [[ $INIT_SYSTEM == systemd ]] && has nft && systemctl is-active --quiet nftables 2>/dev/null; then
		printf nftables
	else
		printf iptables
	fi
}

open_firewall() {
	local backend
	backend=$(firewall_backend)
	step "Opening $PORT/$PROTO and enabling NAT out of $NIC ($backend)"

	if [[ $backend == firewalld ]] &&
		! firewall-cmd --permanent --zone="$(firewalld_zone)" --query-masquerade >/dev/null 2>&1; then
		printf 'FW_ADDED_MASQ=yes\n' >>"$SETTINGS"
	fi
	if [[ $backend == nftables ]] && nft list ruleset 2>/dev/null | grep -q 'policy drop'; then
		warn "nftables has a 'policy drop' chain. Rules in other tables cannot override it, so allow $PORT/$PROTO and forwarding for $TUN_DEV there if clients cannot connect."
	fi
	# ufw's default deny lives in its own chains, which our first-position jumps
	# bypass. This rule is here so `ufw status` shows the port as open.
	if has ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
		quiet ufw allow "$PORT/$PROTO" comment ur-vpn
	fi
	firewall_up
	if selinux_uses_custom_port; then
		selinux_label_port
	fi
}

firewall_up() {
	load_settings
	"firewall_up_$(firewall_backend)"
}

# firewalld rules are permanent, so only uninstall removes them. The other
# backends are tied to the lifetime of the service.
firewall_down() {
	load_settings
	firewall_down_nftables
	firewall_down_iptables
}

ipt() { "$IPT" -w 5 "$@"; }

# Some VPS kernels (older OpenVZ/LXC) have no nf_tables, so try the legacy binary.
find_iptables() {
	local binary
	for binary in "$1" "$1-legacy"; do
		if has "$binary" && "$binary" -w 5 -S INPUT >/dev/null 2>&1; then
			printf '%s' "$binary"
			return 0
		fi
	done
	return 1
}

ipt_fresh_chain() {
	local table=$1 chain=$2
	ipt -t "$table" -N "$chain" 2>/dev/null || ipt -t "$table" -F "$chain"
}

# Position 1 matters: Oracle Cloud images ship a catch-all REJECT in INPUT and FORWARD.
ipt_jump_first() {
	local table=$1 parent=$2 chain=$3
	ipt -t "$table" -C "$parent" -j "$chain" 2>/dev/null || ipt -t "$table" -I "$parent" 1 -j "$chain"
}

ipt_remove_chain() {
	local table=$1 parent=$2 chain=$3
	while ipt -t "$table" -D "$parent" -j "$chain" 2>/dev/null; do :; done
	ipt -t "$table" -F "$chain" 2>/dev/null || true
	ipt -t "$table" -X "$chain" 2>/dev/null || true
}

ipt_allow_vpn_out() {
	local subnet=$1
	ipt_fresh_chain filter UR_VPN_FWD
	ipt -A UR_VPN_FWD -i "$TUN_DEV" -o "$TUN_DEV" -j DROP # clients cannot reach each other
	ipt -A UR_VPN_FWD -i "$TUN_DEV" -o "$NIC" -s "$subnet" -j ACCEPT
	ipt -A UR_VPN_FWD -i "$NIC" -o "$TUN_DEV" -d "$subnet" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
	ipt_jump_first filter FORWARD UR_VPN_FWD

	ipt_fresh_chain nat UR_VPN_NAT
	ipt -t nat -A UR_VPN_NAT -s "$subnet" -o "$NIC" -j MASQUERADE
	ipt_jump_first nat POSTROUTING UR_VPN_NAT
}

firewall_up_iptables() {
	IPT=$(find_iptables iptables) || die "iptables is not usable on this kernel"
	ipt_fresh_chain filter UR_VPN_IN
	ipt -A UR_VPN_IN -p "$PROTO" --dport "$PORT" -j ACCEPT
	ipt -A UR_VPN_IN -i "$TUN_DEV" -p icmp -j ACCEPT
	ipt_jump_first filter INPUT UR_VPN_IN
	ipt_allow_vpn_out "$NET_BASE.0.0/24"

	if [[ $IPV6_EGRESS == yes ]] && IPT=$(find_iptables ip6tables); then
		ipt_allow_vpn_out "$NET6/64"
	fi
}

firewall_down_iptables() {
	local family
	for family in iptables ip6tables; do
		IPT=$(find_iptables "$family") || continue
		ipt_remove_chain filter INPUT UR_VPN_IN
		ipt_remove_chain filter FORWARD UR_VPN_FWD
		ipt_remove_chain nat POSTROUTING UR_VPN_NAT
	done
}

firewall_up_nftables() {
	local ipv6_nat=""
	if [[ $IPV6_EGRESS == yes ]]; then
		ipv6_nat="ip6 saddr $NET6/64 oifname \"$NIC\" masquerade"
	fi
	nft -f - <<EOF
table inet ur_vpn
delete table inet ur_vpn
table inet ur_vpn {
	chain input {
		type filter hook input priority -10;
		$PROTO dport $PORT accept
		iifname "$TUN_DEV" meta l4proto { icmp, ipv6-icmp } accept
	}
	chain forward {
		type filter hook forward priority -10;
		iifname "$TUN_DEV" oifname "$TUN_DEV" drop
		iifname "$TUN_DEV" oifname "$NIC" accept
		iifname "$NIC" oifname "$TUN_DEV" ct state established,related accept
	}
	chain postrouting {
		type nat hook postrouting priority 100;
		ip saddr $NET_BASE.0.0/24 oifname "$NIC" masquerade
		$ipv6_nat
	}
}
EOF
}

firewall_down_nftables() {
	if has nft; then
		nft delete table inet ur_vpn 2>/dev/null || true
	fi
}

firewalld_zone() {
	firewall-cmd --get-zone-of-interface="$NIC" 2>/dev/null || firewall-cmd --get-default-zone
}

# Apply a rule now and across restarts.
firewalld_both() {
	firewall-cmd --permanent "$@" >/dev/null 2>&1 || true
	firewall-cmd "$@" >/dev/null 2>&1 || true
}

firewalld_rules() {
	local action=$1 zone
	zone=$(firewalld_zone)
	firewalld_both --zone="$zone" "--$action-port=$PORT/$PROTO"
	firewalld_both --zone=trusted "--$action-source=$NET_BASE.0.0/24"
	if [[ $IPV6_EGRESS == yes ]]; then
		firewalld_both --zone=trusted "--$action-source=$NET6/64"
	fi
	# Only undo masquerading if we were the ones who turned it on.
	if [[ $action == add || ${FW_ADDED_MASQ:-no} == yes ]]; then
		firewalld_both --zone="$zone" "--$action-masquerade"
	fi
}

firewall_up_firewalld() { firewalld_rules add; }

# SELinux only has the standard port labelled for OpenVPN.

selinux_uses_custom_port() {
	selinux_enforcing && [[ ! ($PORT == 1194 && $PROTO == udp) ]]
}

selinux_label_port() {
	if ! has semanage; then
		warn "semanage is missing, so SELinux may block port $PORT/$PROTO"
		return 0
	fi
	semanage port -a -t openvpn_port_t -p "$PROTO" "$PORT" >>"$LOG" 2>&1 ||
		semanage port -m -t openvpn_port_t -p "$PROTO" "$PORT" >>"$LOG" 2>&1 ||
		warn "could not label $PORT/$PROTO for SELinux"
}

selinux_unlabel_port() {
	if has semanage; then
		semanage port -d -t openvpn_port_t -p "$PROTO" "$PORT" >>"$LOG" 2>&1 || true
	fi
}

# --- Chapter 6: the service ---------------------------------------------------

write_service() {
	step "Installing the $SERVICE service"
	if [[ $INIT_SYSTEM == systemd ]]; then
		write_systemd_unit
	else
		write_openrc_script
	fi
	if selinux_enforcing && has restorecon; then
		restorecon -RF /etc/openvpn >>"$LOG" 2>&1
	fi
}

# The distro's own openvpn-server@ unit differs too much between distros (user,
# paths, a LimitNPROC that breaks containers), so use one known-good unit. Its
# sandboxing follows upstream's. The '+' runs the firewall hooks outside it.
write_systemd_unit() {
	local type=simple
	if openvpn --version 2>/dev/null | grep -q 'enable_systemd=yes'; then
		type=notify
	fi
	cat >"/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=ur-vpn OpenVPN server
After=network-online.target firewalld.service ufw.service nftables.service iptables.service ip6tables.service netfilter-persistent.service
Wants=network-online.target

[Service]
Type=$type
RuntimeDirectory=openvpn-server
WorkingDirectory=$OVPN_DIR
ExecStartPre=+$BIN firewall-up
ExecStart=$(command -v openvpn) --suppress-timestamps --status $STATUS_FILE 10 --status-version 2 --config server.conf
ExecStopPost=+$BIN firewall-down
Restart=on-failure
RestartSec=5
KillMode=process
PrivateTmp=true
ProtectSystem=true
ProtectHome=true
DeviceAllow=/dev/null rw
DeviceAllow=/dev/net/tun rw
CapabilityBoundingSet=CAP_IPC_LOCK CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SETGID CAP_SETUID CAP_SETPCAP CAP_SYS_CHROOT CAP_DAC_OVERRIDE CAP_SYS_NICE CAP_AUDIT_WRITE

[Install]
WantedBy=multi-user.target
EOF
	chmod 644 "/etc/systemd/system/$SERVICE.service"
	systemctl daemon-reload
}

write_openrc_script() {
	cat >"/etc/init.d/$SERVICE" <<EOF
#!/sbin/openrc-run
description="ur-vpn OpenVPN server"
command="$(command -v openvpn)"
command_args="--cd $OVPN_DIR --config server.conf --status $STATUS_FILE 10 --status-version 2 --log-append /var/log/ur-vpn.log"
command_background=yes
pidfile="/run/$SERVICE.pid"
depend() { need net; after firewall; }
start_pre() { mkdir -p /run/openvpn-server; $BIN firewall-up; }
stop_post() { $BIN firewall-down; }
EOF
	chmod 755 "/etc/init.d/$SERVICE"
}

start_service() {
	if [[ $INIT_SYSTEM == systemd ]]; then
		quiet systemctl enable "$SERVICE"
	else
		quiet rc-update add "$SERVICE" default
	fi
	restart_service
}

restart_service() {
	if [[ $INIT_SYSTEM == systemd ]]; then
		systemctl restart "$SERVICE"
	else
		rc-service "$SERVICE" restart
	fi
}

stop_service_if_running() {
	if [[ $INIT_SYSTEM == systemd ]]; then
		systemctl stop "$SERVICE" >/dev/null 2>&1 || true
	else
		rc-service "$SERVICE" stop >/dev/null 2>&1 || true
	fi
}

service_is_active() {
	if [[ $INIT_SYSTEM == systemd ]]; then
		systemctl is-active --quiet "$SERVICE"
	else
		rc-service "$SERVICE" status >/dev/null 2>&1
	fi
}

show_service_log() {
	if [[ $INIT_SYSTEM == systemd ]]; then
		journalctl -u "$SERVICE" --no-pager -n "$1"
	else
		tail -n "$1" /var/log/ur-vpn.log 2>/dev/null
	fi
}

disable_service() {
	if [[ $INIT_SYSTEM == systemd ]]; then
		systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
	else
		rc-service "$SERVICE" stop >/dev/null 2>&1 || true
		rc-update del "$SERVICE" default >/dev/null 2>&1 || true
	fi
}

remove_service() {
	disable_service
	if [[ $INIT_SYSTEM == systemd ]]; then
		rm -f "/etc/systemd/system/$SERVICE.service"
		systemctl daemon-reload
	else
		rm -f "/etc/init.d/$SERVICE"
	fi
}

server_is_up() {
	service_is_active && ip link show "$TUN_DEV" >/dev/null 2>&1 && port_in_use "$PROTO" "$PORT"
}

verify_server() {
	step "Checking the server is really up"
	wait_until 10 server_is_up && return 0
	show_service_log 30 >&2 || true
	die "the OpenVPN service did not come up. See the log above."
}

# --- Chapter 7: client profiles -----------------------------------------------

is_valid_name() { [[ $1 =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }

check_name() {
	local name=$1 usage=$2
	[[ -n $name ]] || die "usage: $usage"
	is_valid_name "$name" || die "client name must be 1-32 letters, numbers, - or _"
	[[ $name != "$SERVER_CN" ]] || die "that name is reserved"
}

pem_only() { sed -n '/-----BEGIN/,/-----END/p' "$1"; }

profile_cipher_config() {
	if [[ $TLS_MODE == v2 ]]; then
		printf 'data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305'
	else
		printf 'cipher AES-256-GCM'
	fi
}

# Each client gets its own control-channel key, so one leaked profile doesn't
# expose a key every device shares. OpenVPN 2.4 only has the shared kind.
profile_tls_key() {
	local client_key=$1
	if [[ $TLS_MODE == v2 ]]; then
		printf '<tls-crypt-v2>\n%s\n</tls-crypt-v2>\n' "$(cat "$client_key")"
	else
		printf '<tls-crypt>\n%s\n</tls-crypt>\n' "$(cat "$OVPN_DIR/tc.key")"
	fi
}

build_profile() {
	local name=$1 client_key="$CLIENTS_DIR/.$1.tc-v2"
	(
		umask 077
		if [[ ! -f $PKI_DIR/pki/issued/$name.crt ]]; then
			quiet easyrsa build-client-full "$name" nopass
		fi
		if [[ $TLS_MODE == v2 ]]; then
			quiet openvpn --tls-crypt-v2 "$OVPN_DIR/tc-v2.key" --genkey tls-crypt-v2-client "$client_key"
		fi
		cat >"$CLIENTS_DIR/$name.ovpn" <<EOF
# ur-vpn profile for $name
# ur-vpn-dns: $DNS_SERVERS
client
dev tun
proto $PROTO
remote $HOST $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name $SERVER_CN name
tls-version-min 1.2
auth SHA256
ignore-unknown-option block-outside-dns
$(profile_cipher_config)
verb 3
<ca>
$(pem_only "$OVPN_DIR/ca.crt")
</ca>
<cert>
$(pem_only "$PKI_DIR/pki/issued/$name.crt")
</cert>
<key>
$(pem_only "$PKI_DIR/pki/private/$name.key")
</key>
$(profile_tls_key "$client_key")
EOF
		rm -f "$client_key"
	)
}

# Short lines on purpose: macOS terminals silently cut pasted lines at 1024
# bytes, so one long base64 string would arrive damaged.
print_profile_block() {
	printf '%s\n' '-----BEGIN UR-VPN PROFILE-----'
	gzip -9nc "$CLIENTS_DIR/$1.ovpn" | base64 | tr -d '\n' | fold -w 64
	printf '\n%s\n' '-----END UR-VPN PROFILE-----'
}

# --- Chapter 8: telling the user what to do next ------------------------------

print_finish() {
	cat <<EOF

${GREEN}${BOLD}Server is ready.${RESET} $HOST:$PORT/$PROTO, tunnel $NET_BASE.0.0/24, egress $NIC

${BOLD}Step 1: open the port in your provider's firewall, if it has one.${RESET}
This machine's firewall is done, but a script cannot change your provider's.
  $(provider_firewall_hint)

${BOLD}Manage it later on this server:${RESET}
  ur-vpn add NAME      new client for another device
  ur-vpn show NAME     show a client's paste block again (--raw for an .ovpn file, for phones)
  ur-vpn revoke NAME   cut off a client
  ur-vpn list | status | logs | uninstall

${BOLD}Step 2:${RESET}
EOF
	print_client_steps "$1"
}

print_client_steps() {
	cat <<EOF
${BOLD}Set up the client device: run the command for its system.${RESET}

  ${CYAN}macOS / Linux${RESET} (Terminal):
    curl -fsSL $UR_VPN_RAW/client.sh | bash

  ${CYAN}Windows${RESET} (PowerShell):
    irm $UR_VPN_RAW/client.ps1 | iex

${BOLD}When it asks, paste this whole block, including the BEGIN and END lines.${RESET}
It is the login for "$1": treat it like a password, and use a new client per device.

EOF
	print_profile_block "$1"
	printf '\n'
}

provider_firewall_hint() {
	local vendor="" field rule="$PORT/$PROTO"
	for field in sys_vendor board_vendor bios_vendor chassis_vendor chassis_asset_tag product_name; do
		if [[ -r /sys/class/dmi/id/$field ]]; then
			vendor+=" $(cat "/sys/class/dmi/id/$field" 2>/dev/null)"
		fi
	done
	case $vendor in
	*Amazon*)            printf 'AWS: EC2 > your instance > Security > Security groups > Edit inbound rules > add %s from 0.0.0.0/0' "$rule" ;;
	*Google*)            printf 'Google Cloud: run  gcloud compute firewall-rules create ur-vpn --allow %s:%s  or use VPC network > Firewall' "$PROTO" "$PORT" ;;
	*Microsoft*)         printf 'Azure: VM > Networking > Add inbound port rule > %s' "$rule" ;;
	*Oracle*)            printf 'Oracle Cloud: Networking > VCN > Security List (or NSG) > Add Ingress Rule > %s from 0.0.0.0/0' "$rule" ;;
	*DigitalOcean*)      printf 'DigitalOcean: only if a Cloud Firewall is attached: Networking > Firewalls > add inbound %s' "$rule" ;;
	*Hetzner*)           printf 'Hetzner: only if a Cloud Firewall is attached: Console > Firewalls > add inbound %s' "$rule" ;;
	*Vultr*)             printf 'Vultr: only if a Firewall Group is attached: Products > Network > Firewall > add %s' "$rule" ;;
	*Linode* | *Akamai*) printf 'Linode: only if a Cloud Firewall is attached: Firewalls > add inbound %s' "$rule" ;;
	*Alibaba*)           printf 'Alibaba Cloud: ECS > Security Groups > add inbound %s' "$rule" ;;
	*Tencent*)           printf 'Tencent Cloud: Security Groups > add inbound %s' "$rule" ;;
	*)                   printf 'If your provider has a firewall in its web panel, allow inbound %s there' "$rule" ;;
	esac
}

# ==============================================================================
#  The ur-vpn command
# ==============================================================================

cmd_add() {
	load_settings
	local name=${1:-}
	check_name "$name" "ur-vpn add NAME"
	[[ ! -f $CLIENTS_DIR/$name.ovpn ]] || die "'$name' already exists. Show it with: ur-vpn show $name"
	build_profile "$name"
	printf 'Client %s created.\n\n' "$name"
	print_client_steps "$name"
}

cmd_show() {
	load_settings
	local name=${1:-} format=${2:-}
	check_name "$name" "ur-vpn show NAME [--raw]"
	[[ -f $CLIENTS_DIR/$name.ovpn ]] || die "no client named '$name'. See: ur-vpn list"
	if [[ $format == --raw ]]; then
		cat "$CLIENTS_DIR/$name.ovpn"
	else
		print_client_steps "$name"
	fi
}

cmd_revoke() {
	load_settings
	local name=${1:-}
	check_name "$name" "ur-vpn revoke NAME"
	[[ -f $PKI_DIR/pki/issued/$name.crt ]] || die "no active client named '$name'"
	quiet easyrsa revoke "$name"
	quiet easyrsa gen-crl
	install -m 644 "$PKI_DIR/pki/crl.pem" "$OVPN_DIR/crl.pem"
	rm -f "$CLIENTS_DIR/$name.ovpn"
	# The CRL is only checked on new connections, so restart to drop any live
	# session. Other clients reconnect by themselves within seconds.
	if service_is_active; then
		restart_service
	fi
	printf 'Client %s revoked and disconnected.\n' "$name"
}

cmd_list() {
	load_settings
	printf '%-32s %s\n' NAME STATE
	awk -F'\t' -v server="$SERVER_CN" '
		BEGIN { state["V"] = "active"; state["R"] = "revoked" }
		{
			name = $NF
			sub(/.*CN=/, "", name)
			sub(/\/.*/, "", name)
			if (name != server) printf "%-32s %s\n", name, ($1 in state ? state[$1] : "expired")
		}' "$PKI_DIR/pki/index.txt"
}

cmd_status() {
	load_settings
	if service_is_active; then
		printf 'Service:  %srunning%s\n' "$GREEN" "$RESET"
	else
		printf 'Service:  %sstopped%s\n' "$RED" "$RESET"
	fi
	printf 'Endpoint: %s:%s/%s\n' "$HOST" "$PORT" "$PROTO"
	printf 'Tunnel:   %s (%s.0.0/24)\n' "$TUN_DEV" "$NET_BASE"
	printf 'Egress:   %s\n' "$NIC"
	printf 'Connected clients:\n'
	if [[ -r $STATUS_FILE ]]; then
		awk -F, '
			$1 == "CLIENT_LIST" { printf "  %-24s %-22s %s\n", $2, $3, $4; found = 1 }
			END { if (!found) print "  none" }' "$STATUS_FILE"
	else
		printf '  none\n'
	fi
}

cmd_start() {
	load_settings
	if service_is_active; then
		printf 'Already running.\n'
		return 0
	fi
	step "Starting the $SERVICE service"
	start_service
	verify_server
	printf 'Started. Clients reconnect by themselves within seconds.\n'
}

cmd_stop() {
	load_settings
	step "Stopping the $SERVICE service"
	disable_service
	printf 'Stopped. It stays off, even after a reboot, until: ur-vpn start\n'
}

cmd_restart() {
	load_settings
	step "Restarting the $SERVICE service"
	start_service
	verify_server
	printf 'Restarted. Clients reconnect by themselves within seconds.\n'
}

cmd_logs() {
	load_settings
	show_service_log "${1:-40}"
}

cmd_update() {
	[[ -f $INSTALLED_MARK ]] || die "ur-vpn is not installed on this machine"
	UPDATE_DIR=$(mktemp -d)
	local version was_running=no

	step "Checking for a new release"
	download_release "$UPDATE_DIR"
	version=$(sed -n 's/^readonly VERSION=//p' "$UPDATE_DIR/server.sh")
	if [[ $version == "$VERSION" ]]; then
		printf 'Already on the latest release, %s.\n' "$VERSION"
		return 0
	fi

	step "Updating from $VERSION to $version"
	if service_is_active; then
		was_running=yes
	fi
	cp -p "$BIN" "$UPDATE_DIR/previous"
	replace_command "$UPDATE_DIR/server.sh"
	if "$BIN" apply-update; then
		printf 'Updated to %s.\n' "$version"
		return 0
	fi

	replace_command "$UPDATE_DIR/previous"
	"$BIN" apply-update || true
	if [[ $was_running == yes ]]; then
		restart_service || true
	fi
	die "the update to $version failed, so the server went back to $VERSION. See: ur-vpn logs"
}

download_release() {
	local dir=$1 expected actual
	fetch "$UR_VPN_RELEASE_URL/server.sh" "$dir/server.sh" ||
		die "could not download the latest release from $UR_VPN_RELEASE_URL"
	fetch "$UR_VPN_RELEASE_URL/SHA256SUMS" "$dir/SHA256SUMS" ||
		die "could not download the checksums from $UR_VPN_RELEASE_URL"

	expected=$(awk '$2 == "server.sh" { print $1 }' "$dir/SHA256SUMS")
	actual=$(sha256sum "$dir/server.sh" | cut -d' ' -f1)
	[[ -n $expected && $expected == "$actual" ]] || die "the download failed its checksum. Nothing was changed."
	bash -n "$dir/server.sh" || die "the download is not a valid script. Nothing was changed."
	grep -q '^readonly VERSION=' "$dir/server.sh" || die "the download has no version. Nothing was changed."
}

# The rename is atomic, and a script already running keeps reading the old file.
replace_command() {
	install -m 755 "$1" "$BIN.new"
	mv -f "$BIN.new" "$BIN"
}

# Runs from the new copy, so a release's changes to the config and service apply.
# Connected clients are only disturbed if one of them really changed.
cmd_apply_update() {
	load_settings
	local before
	before=$(installed_config | cksum)
	write_server_config
	write_service
	if [[ $(installed_config | cksum) == "$before" ]] || ! service_is_active; then
		return 0
	fi
	step "Restarting the service. Clients reconnect by themselves within seconds."
	restart_service
	verify_server
}

installed_config() {
	local service_file=/etc/init.d/$SERVICE
	if [[ $INIT_SYSTEM == systemd ]]; then
		service_file=/etc/systemd/system/$SERVICE.service
	fi
	cat "$OVPN_DIR/server.conf" "$service_file"
}

cmd_uninstall() {
	load_settings
	if [[ ${1:-} != --yes ]]; then
		printf 'This removes the VPN, its firewall rules, the CA and every client certificate.\n'
		printf 'All clients stop working for good. Type "yes" to continue: '
		local answer=""
		read -r answer </dev/tty || true
		[[ $answer == yes ]] || die "cancelled"
	fi

	step "Removing ur-vpn"
	remove_service
	firewall_down
	if firewalld_running; then
		firewalld_rules remove
	fi
	if has ufw; then
		ufw delete allow "$PORT/$PROTO" >/dev/null 2>&1 || true
	fi
	if selinux_uses_custom_port; then
		selinux_unlabel_port
	fi
	rm -f "$SYSCTL_FILE" "$BIN"
	rm -rf "$OVPN_DIR" "$STATE_DIR"
	printf 'Removed. The openvpn package is still installed; IP forwarding stays on until the next reboot.\n'
}

usage() {
	cat <<EOF
ur-vpn: OpenVPN server manager

  server.sh               install everything (safe to re-run)
  ur-vpn add NAME         create a client and print its paste block
  ur-vpn show NAME        print a client's paste block  (--raw: .ovpn text)
  ur-vpn revoke NAME      revoke a client and disconnect it
  ur-vpn list             list clients
  ur-vpn start            start the VPN, and start it at boot
  ur-vpn stop             stop the VPN, and keep it off
  ur-vpn restart          restart the VPN
  ur-vpn status           service state and connected clients
  ur-vpn logs [LINES]     recent server log
  ur-vpn update           move to the latest release
  ur-vpn version          print the installed version
  ur-vpn uninstall        remove everything  (--yes: skip the prompt)
EOF
}

main() {
	trap 'on_unexpected_error $LINENO' ERR
	local command=${1:-install}
	case $command in
	-h | --help | help)
		usage
		return 0
		;;
	version)
		printf '%s\n' "$VERSION"
		return 0
		;;
	esac

	bootstrap "$@"
	trap remove_temp_files EXIT
	detect_system
	if (($# > 0)); then shift; fi

	case $command in
	install) cmd_install ;;
	add) cmd_add "$@" ;;
	show) cmd_show "$@" ;;
	revoke) cmd_revoke "$@" ;;
	list) cmd_list ;;
	start) cmd_start ;;
	stop) cmd_stop ;;
	restart) cmd_restart ;;
	status) cmd_status ;;
	logs) cmd_logs "$@" ;;
	update) cmd_update ;;
	apply-update) cmd_apply_update ;;
	uninstall) cmd_uninstall "$@" ;;
	firewall-up) firewall_up ;;
	firewall-down) firewall_down ;;
	*)
		usage >&2
		exit 2
		;;
	esac
}

if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then
	main "$@"
fi
