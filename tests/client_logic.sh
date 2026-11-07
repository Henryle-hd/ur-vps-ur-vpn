#!/bin/bash
#
# Tests the client.sh logic Docker can't reach: decoding profiles under the bash
# 3.2 that macOS ships, and macOS DNS and launchd setup, using stubs. It changes
# nothing on the system and needs no sudo.
#
#     /bin/bash tests/client_logic.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
export TMPDIR=$WORK
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

report() {
	if [[ $1 == pass ]]; then
		printf '  ok    %s\n' "$2"
		passed=$((passed + 1))
	else
		printf '  FAIL  %s\n' "$2"
		failed=$((failed + 1))
	fi
}

expect() {
	local name=$1
	shift
	if ("$@") >/dev/null 2>&1; then report pass "$name"; else report fail "$name"; fi
}

refuses() {
	local name=$1
	shift
	if ("$@") >/dev/null 2>&1; then report fail "$name"; else report pass "$name"; fi
}

# --- Load client.sh with its system paths pointing into the work directory ----

sed -e "s#readonly STATE_DIR=.*#readonly STATE_DIR=$WORK/state#" \
	-e "s#readonly MAC_PLIST=.*#readonly MAC_PLIST=$WORK/test.plist#" \
	-e "s#readonly BIN=.*#readonly BIN=$WORK/bin/ur-vpn#" \
	-e "s#/usr/sbin/networksetup#$WORK/networksetup#g" \
	-e "s#/usr/bin/dscacheutil#true#g" \
	-e "s#/usr/bin/killall#true#g" \
	"$REPO/client.sh" >"$WORK/client.sh"
# shellcheck disable=SC1091
. "$WORK/client.sh"
set +eE

printf 'bash %s\n' "$BASH_VERSION"

# --- Fixtures -----------------------------------------------------------------

cat >"$WORK/sample.ovpn" <<'EOF'
# ur-vpn-dns: 8.8.8.8 8.8.4.4
client
dev tun
proto udp
remote 203.0.113.9 1194
<ca>
x
</ca>
<key>
y
</key>
EOF

{
	printf '%s\n' '-----BEGIN UR-VPN PROFILE-----'
	gzip -9nc "$WORK/sample.ovpn" | base64 | tr -d '\n' | fold -w 64
	printf '\n%s\n' '-----END UR-VPN PROFILE-----'
} >"$WORK/block.txt"

# What a paste can pick up: carriage returns, indentation, nearby text.
{
	printf 'some terminal noise\r\n'
	sed 's/^/   /; s/$/  \r/' "$WORK/block.txt"
	printf 'hdlee@vps:~$ \r\n'
} >"$WORK/dirty.txt"

awk 'NR == 3 { $0 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" substr($0, 33) } { print }' "$WORK/block.txt" >"$WORK/damaged.txt"
sed '$d' "$WORK/block.txt" >"$WORK/cut_off.txt"
printf 'not a profile\n' >"$WORK/junk.txt"

decodes_to_sample() { get_profile "$1" && cmp -s "$PROFILE" "$WORK/sample.ovpn"; }

paste_decodes_to_sample() {
	UR_VPN_TTY=$WORK/block.txt
	read_pasted_block
	[[ "$(decode_block "$PASTED_BLOCK")" == "$(cat "$WORK/sample.ovpn")" ]]
}

# --- Reading the profile ------------------------------------------------------

expect "block decodes to the exact profile" decodes_to_sample "$WORK/block.txt"
expect "survives CRLF, indents and surrounding text" decodes_to_sample "$WORK/dirty.txt"
expect "accepts a plain .ovpn" decodes_to_sample "$WORK/sample.ovpn"
expect "reads a paste from the terminal" paste_decodes_to_sample
refuses "rejects a damaged block" get_profile "$WORK/damaged.txt"
refuses "rejects a block with no END line" get_profile "$WORK/cut_off.txt"
refuses "rejects a file that isn't a profile" get_profile "$WORK/junk.txt"

PROFILE=$WORK/sample.ovpn
expect "reads the remote" test "$(profile_remote)" = "203.0.113.9:1194"
expect "reads the port and protocol" test "$(profile_port_and_proto)" = "1194/udp"
expect "reads the DNS servers" test "$(profile_dns)" = "8.8.8.8 8.8.4.4"

printf 'client\nremote 1.2.3.4 1194\ndhcp-option DNS 4.4.4.4\n' >"$WORK/foreign.ovpn"
PROFILE=$WORK/foreign.ovpn
expect "falls back to DNS from a plain profile" test "$(profile_dns)" = "4.4.4.4 "

# --- Updating, from a fake release in the work directory ----------------------

mkdir -p "$WORK/bin" "$WORK/release"
cp "$WORK/client.sh" "$BIN"
UR_VPN_RELEASE_URL=file://$WORK/release

publish_release() {
	sed "s/^readonly UR_VPN_VERSION=dev\$/readonly UR_VPN_VERSION=$1/" "$WORK/client.sh" >"$WORK/release/client.sh"
	printf '%s  client.sh\n' "$(sha256_of "$WORK/release/client.sh")" >"$WORK/release/SHA256SUMS"
}

installed_version() { sed -n 's/^readonly UR_VPN_VERSION=//p' "$BIN"; }

says_up_to_date() { cmd_update | grep -q 'Already on the latest'; }

publish_release dev
expect "update: says when already up to date" says_up_to_date

publish_release v9.9.9
expect "update: installs a new release" cmd_update
expect "update: the command is the new version" test "$(installed_version)" = v9.9.9
expect "update: the command stays executable" test -x "$BIN"

publish_release v9.9.10
printf '# changed after the checksum\n' >>"$WORK/release/client.sh"
refuses "update: rejects a tampered release" cmd_update

printf 'if then\n' >"$WORK/release/client.sh"
printf '%s  client.sh\n' "$(sha256_of "$WORK/release/client.sh")" >"$WORK/release/SHA256SUMS"
refuses "update: rejects a release that does not parse" cmd_update
expect "update: a rejected release changes nothing" test "$(installed_version)" = v9.9.9

rm -f "$WORK/release/client.sh"
refuses "update: fails cleanly with no release to download" cmd_update

# --- macOS DNS, with a fake networksetup that records each call ---------------

mkdir -p "$WORK/state"
printf '8.8.8.8 8.8.4.4' >"$WORK/state/dns"

cat >"$WORK/networksetup" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$WORK/calls"
case "\$1" in
-listallnetworkservices)
	printf 'An asterisk (*) denotes that a network service is disabled.\nWi-Fi\nUSB 10/100 LAN\n*Bluetooth PAN\n'
	;;
-getdnsservers)
	if [ "\$2" = "Wi-Fi" ]; then
		printf '192.168.1.1\n192.168.1.2\n'
	else
		printf "There aren't any DNS Servers set on %s.\n" "\$2"
	fi
	;;
esac
EOF
chmod +x "$WORK/networksetup"

called() { grep -q -- "$1" "$WORK/calls"; }

mac_dns_up
expect "macOS: DNS set on Wi-Fi" called '-setdnsservers Wi-Fi 8.8.8.8 8.8.4.4'
expect "macOS: handles a service name with spaces" called '-setdnsservers USB 10/100 LAN 8.8.8.8 8.8.4.4'
refuses "macOS: skips disabled services" called 'Bluetooth'

mac_dns_up # a reconnect
expect "macOS: a reconnect keeps the original DNS backup" grep -q '192.168.1.1' "$WORK/state/dns-backup"

: >"$WORK/calls"
mac_dns_down
expect "macOS: original DNS restored" called '-setdnsservers Wi-Fi 192.168.1.1 192.168.1.2'
expect "macOS: an unset service goes back to automatic" called '-setdnsservers USB 10/100 LAN Empty'
expect "macOS: backup removed after restore" test ! -f "$WORK/state/dns-backup"

# --- macOS service commands, with a fake launchctl that records each call -----

launchctl() { printf '%s ' "$1" >>"$WORK/launchctl-calls"; }

mac_restart
expect "macOS: restart reloads the service" test "$(cat "$WORK/launchctl-calls")" = "bootout bootstrap "

# --- macOS launchd plist ------------------------------------------------------

mac_openvpn() { printf '/opt/homebrew/sbin/openvpn'; }
install() {
	local args=("$@")
	cp "${args[${#args[@]} - 2]}" "${args[${#args[@]} - 1]}"
}

mac_write_service
if [[ $(uname -s) == Darwin ]]; then
	expect "macOS: launchd plist is valid" plutil -lint "$WORK/test.plist"
fi
expect "macOS: starts at boot" grep -q 'RunAtLoad' "$WORK/test.plist"
expect "macOS: plist runs the Homebrew openvpn" grep -q '/opt/homebrew/sbin/openvpn' "$WORK/test.plist"

# --- The live view, with a fake tunnel ------------------------------------------

PLATFORM=mac
launchctl() { return 0; }
route() { printf '   route to: 1.1.1.1\n  gateway: 10.8.0.1\n  interface: utun4\n'; }
netstat() {
	printf 'Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\n'
	printf 'utun4 1500 <Link#18> 200 0 5242880 100 0 1048576 0\n'
	printf 'utun4 1500 10.8.0.2 10.8.0.2 200 0 5242880 100 0 1048576 -\n'
}
expect "top: reads the tunnel's bytes on macOS" test "$(mac_tunnel_bytes)" = "5242880 1048576"

route() { printf '  interface: en0\n'; }
expect "top: another route means no tunnel" test -z "$(mac_tunnel_bytes)"
route() { printf '  interface: utun4\n'; }
launchctl() { return 1; }
expect "top: a stopped service means no tunnel" test -z "$(mac_tunnel_bytes)"
launchctl() { return 0; }

health_is() {
	TOP_RX=$1 TOP_SENT=$2 TOP_LOST=$3 TOP_MISSES=$4 TOP_LATENCY=$5
	case $(top_health) in
	"$6"*) return 0 ;;
	*) return 1 ;;
	esac
}
expect "top: not connected" health_is "" 0 0 0 "" "not connected"
expect "top: checking before the first ping" health_is 1 0 0 0 "" "checking"
expect "top: good" health_is 1 5 0 0 "20.5" "good"
expect "top: slow on high latency" health_is 1 5 0 0 "450.1" "slow"
expect "top: slow on packet loss" health_is 1 10 2 0 "20.5" "slow"
expect "top: one lost ping is not an outage" health_is 1 1 1 1 "" "good"
expect "top: no internet after several lost pings" health_is 1 5 3 3 "" "no internet"

record_halves() {
	TOP_SENT=39 TOP_LOST=4
	top_record_ping ""
	[[ $TOP_SENT == 20 && $TOP_LOST == 2 ]]
}
expect "top: loss is about recent pings" record_halves

a_reply_clears_misses() {
	TOP_SENT=0 TOP_LOST=0 TOP_MISSES=0 TOP_LATENCY=""
	top_record_ping ""
	top_record_ping 30.0
	[[ $TOP_MISSES == 0 && $TOP_LATENCY == 30.0 ]]
}
expect "top: a reply clears the missed pings" a_reply_clears_misses

ping_reads_ms() {
	mac_ping_ms() { printf 'PING\n64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=34.2 ms\n'; }
	[[ $(top_ping) == 34.2 ]]
}
expect "top: reads the round trip from ping" ping_reads_ms

frame_shows() {
	TOP_RX=5242880 TOP_TX=1048576 TOP_RX_RATE=2097152 TOP_TX_RATE=1024 TOP_SENT=1 TOP_LOST=0
	TOP_LATENCY=34.2 TOP_PUBLIC_IP=203.0.113.9 TOP_SERVER=203.0.113.9:1194/udp
	top_frame | grep "$1" >/dev/null
}
expect "top: shows the speed" frame_shows 'down 2.0 MB/s'
expect "top: shows the upload" frame_shows 'up 1.0 KB/s'
expect "top: shows the total" frame_shows 'down 5.0 MB'
expect "top: shows the latency" frame_shows '34.2 ms'
expect "top: shows the server" frame_shows '203.0.113.9:1194/udp'

prints_once_when_not_a_terminal() {
	public_ip() { printf '203.0.113.9'; }
	has() { return 1; }
	cmd_top --once | grep 'Public IP  203.0.113.9' >/dev/null
}
expect "top: --once prints one frame and returns" prints_once_when_not_a_terminal

printf '\n%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
