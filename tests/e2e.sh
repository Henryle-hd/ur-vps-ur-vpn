#!/usr/bin/env bash
#
# End-to-end test: runs server.sh and client.sh in two systemd containers on a
# private Docker network, then checks a real tunnel, NAT, DNS, revocation,
# re-running and uninstalling.
#
#     tests/e2e.sh ubuntu:24.04 [debian:13 rockylinux/rockylinux:9 ...]
#
# Optional environment:
#
#     SERVER_ENV="VPN_PROTO=tcp VPN_PORT=443"    settings for server.sh
#     SERVER_PREP="apt-get install -y ufw && ufw --force enable"    run before it
#     CLIENT_ARGS="--sysctl net.ipv6.conf.all.disable_ipv6=0"       docker flags
#     KEEP=1                                     leave containers up after a failure
#     MIN_FREE_MB=600                            stop if the host disk gets this low
#
# Containers can't cover SELinux or AppArmor enforcement, or a real cloud firewall.

set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
readonly REPO
readonly NETWORK=urvpn-e2e
readonly PREPARED_IMAGE=urvpn-e2e-prepared
readonly SERVER=urvpn-srv
readonly CLIENT=urvpn-cli
readonly MIN_FREE_MB=${MIN_FREE_MB:-600}
readonly SERVER_STATUS=/run/openvpn-server/status-ur-vpn.log

passed=0
failed=0

# --- Reporting ----------------------------------------------------------------

ok() {
	printf '  ok    %s\n' "$1"
	passed=$((passed + 1))
}

bad() {
	printf '  FAIL  %s\n' "$1"
	failed=$((failed + 1))
}

info() { printf '  info  %s\n' "$1"; }

check() {
	local name=$1
	shift
	if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}

check_output() {
	if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1"; fi
}

on_server() { docker exec "$SERVER" sh -c "$1"; }
on_client() { docker exec "$CLIENT" sh -c "$1"; }

free_mb() { df -m "$HOME" | awk 'NR == 2 { print $4 }'; }

# --- Containers ---------------------------------------------------------------

# Base images have no systemd. Only what the scripts can't install go here.
systemd_install_command() {
	local rpm='command -v dnf >/dev/null && PM=dnf || PM=yum; $PM install -y -q systemd dbus util-linux iproute procps-ng gzip tar hostname >/dev/null 2>&1 || $PM install -y -q systemd dbus-daemon util-linux iproute procps-ng gzip tar >/dev/null; $PM install -y -q util-linux-script >/dev/null 2>&1 || true'
	case $1 in
	ubuntu* | debian*) echo 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends systemd systemd-sysv dbus curl ca-certificates util-linux >/dev/null' ;;
	*suse*) echo 'zypper -q -n install --no-recommends systemd systemd-sysvinit dbus-1 curl util-linux iproute2 gzip tar >/dev/null' ;;
	*archlinux*) echo 'pacman -Sy --noconfirm --needed systemd dbus curl util-linux >/dev/null' ;;
	*) echo "$rpm" ;;
	esac
}

# --privileged is needed for systemd and TUN. The repo is mounted read-only.
# Package caches live in RAM: on the RPM distros they run to hundreds of MB.
run_container() {
	local name=$1 image=$2 command=$3
	shift 3
	# shellcheck disable=SC2086 # command is several words
	docker run -d --name "$name" --hostname "$name" --network "$NETWORK" --privileged \
		--cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
		--tmpfs /var/cache/dnf --tmpfs /var/cache/libdnf5 --tmpfs /var/cache/zypp \
		-v "$REPO:/repo:ro" "$@" "$image" $command >/dev/null
}

prepare_image() {
	local image=$1 builder=urvpn-e2e-builder
	run_container "$builder" "$image" "sleep infinity" || return 1
	docker exec "$builder" sh -c "$(systemd_install_command "$image")" || return 1
	docker commit "$builder" "$PREPARED_IMAGE" >/dev/null
	docker rm -f "$builder" >/dev/null
}

systemd_is_ready() {
	docker exec "$1" sh -c 'test -d /run/systemd/system && systemctl is-system-running 2>/dev/null | grep -Eq "running|degraded"'
}

start_node() {
	local name=$1 _
	shift
	run_container "$name" "$PREPARED_IMAGE" /sbin/init "$@" || return 1
	for _ in $(seq 1 40); do
		systemd_is_ready "$name" && return 0
		sleep 1
	done
	echo "  systemd did not start in $name"
	return 1
}

teardown() {
	docker rm -f "$SERVER" "$CLIENT" urvpn-e2e-builder >/dev/null 2>&1
	docker rmi "$PREPARED_IMAGE" >/dev/null 2>&1
	docker network rm "$NETWORK" >/dev/null 2>&1
}

# Hand freed space back to the host when the VM supports it (Colima).
release_disk_space() {
	if command -v colima >/dev/null 2>&1; then
		colima ssh -- sudo fstrim -a >/dev/null 2>&1
	fi
}

# --- The test, in order -------------------------------------------------------

test_server_install() {
	local output status block longest
	if [[ -n ${SERVER_PREP:-} ]]; then
		on_server "$SERVER_PREP" >/dev/null 2>&1 || bad "SERVER_PREP failed"
	fi

	# Piped into bash, as in the README. file:// stands in for the GitHub download.
	output=$(on_server "cat /repo/server.sh | env UR_VPN_RAW=file:///repo VPN_HOST=$SERVER_IP ${SERVER_ENV:-} bash" 2>&1)
	status=$?
	if [[ $status -eq 0 ]]; then
		ok "server.sh completed"
	else
		bad "server.sh exited $status"
		tail -n 30 <<<"$output"
		on_server 'journalctl -u ur-vpn-server --no-pager -n 30' 2>/dev/null
	fi
	check_output "printed next steps" "$output" "Server is ready"

	block=$(sed -n '/BEGIN UR-VPN PROFILE/,/END UR-VPN PROFILE/p' <<<"$output")
	if [[ -n $block ]]; then ok "printed paste block (${#block} bytes)"; else bad "printed paste block"; fi

	longest=$(awk '{ if (length($0) > max) max = length($0) } END { print max + 0 }' <<<"$block")
	if ((longest < 1024)); then ok "block lines fit the macOS paste limit ($longest chars)"; else bad "block line too long: $longest"; fi

	PASTE_BLOCK=$block
	info "$(docker exec "$SERVER" openvpn --version | head -n 1)"
	info "$(on_server 'grep -E "^(NIC|TLS_MODE|IPV6_EGRESS)=" /etc/ur-vpn/settings.env | tr "\n" " "')"

	check "service is active" on_server 'systemctl is-active --quiet ur-vpn-server'
	check "service is enabled at boot" on_server 'systemctl is-enabled --quiet ur-vpn-server'
	check "CA key is root-only" on_server '[ "$(stat -c %a /etc/ur-vpn)" = 700 ]'
	check "process dropped to nobody" on_server '[ "$(ps -o user= -C openvpn | head -n1)" = nobody ]'
}

# Through a real pty, the way a person pastes it. The delay is them reading the
# prompt: without it the input arrives before the script hides the terminal.
test_client_install() {
	local output status key_line
	docker exec -i "$CLIENT" sh -c 'cat >/tmp/block.txt' <<<"$PASTE_BLOCK"
	output=$(on_client '(sleep 3; cat /tmp/block.txt; i=0; while [ ! -e /tmp/client-done ] && [ $i -lt 900 ]; do sleep 1; i=$((i + 1)); done) |
		script -qec "cat /repo/client.sh | UR_VPN_RAW=file:///repo bash; rc=\$?; touch /tmp/client-done; exit \$rc" /dev/null' 2>&1)
	status=$?
	if [[ $status -eq 0 ]]; then
		ok "client.sh completed from a pasted block"
	else
		bad "client.sh exited $status"
		tail -n 25 <<<"$output"
	fi
	check_output "client reported Connected" "$output" "Connected"

	key_line=$(sed -n 2p <<<"$PASTE_BLOCK")
	if [[ -z $key_line ]]; then
		bad "no block to test hidden paste with"
	elif grep -qF -- "$key_line" <<<"$output"; then
		bad "paste was echoed to the terminal"
	else
		ok "paste stayed hidden"
	fi
}

test_tunnel() {
	check "default route goes through the tunnel" on_client 'ip -4 route get 1.1.1.1 | grep -q "dev urvpn0"'
	check "server stays reachable outside the tunnel" on_client "ip -4 route get $SERVER_IP | grep -qv 'dev urvpn0'"
	check "the server sees the client connected" server_sees_client
	if on_client '[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 0 ]'; then
		check "IPv6 goes into the tunnel, so it cannot leak" on_client 'ip -6 route get 2606:4700:4700::1111 | grep -q "dev urvpn0"'
	fi
	check "client reaches the internet through the VPN" on_client 'curl -4 -fsS --max-time 15 https://api.ipify.org'
	check "NAT counted client traffic on the server" on_server '
		if command -v nft >/dev/null && nft list table inet ur_vpn >/dev/null 2>&1; then exit 0; fi
		if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then exit 0; fi
		iptables -w 5 -t nat -L UR_VPN_NAT -v -n -x | awk "/MASQUERADE/ { if (\$1 > 0) f = 1 } END { exit !f }"'
	check "DNS set to the VPN's servers" on_client 'grep -q "nameserver 1.1.1.1" /etc/resolv.conf || resolvectl dns urvpn0 2>/dev/null | grep -q 1.1.1.1'
	check "server shows the client connected" on_server 'sleep 11; ur-vpn status | grep -q client1'
	check "client status says connected" on_client 'ur-vpn status | grep -q "VPN: connected"'
}

test_rerun() {
	local output
	output=$(on_server "VPN_HOST=$SERVER_IP bash /repo/server.sh" 2>&1)
	check_output "re-running server.sh is safe" "$output" "already installed"
	check_output "re-run prints the block again" "$output" "BEGIN UR-VPN PROFILE"
	check "firewall rules not duplicated by restart" on_server '
		systemctl restart ur-vpn-server
		command -v iptables >/dev/null || exit 0
		[ "$(iptables -w 5 -S INPUT | grep -c UR_VPN_IN)" -le 1 ]'
}

# Publish a fake release inside a container: the repo's script with its version
# stamped, plus any extra sed edit standing in for what a new release changes.
publish_release() {
	local container=$1 script=$2 version=$3 edit=${4:-}
	docker exec "$container" sh -c "mkdir -p /tmp/release && cd /tmp/release &&
		sed -e 's/^readonly VERSION=dev\$/readonly VERSION=$version/' ${edit:+-e '$edit'} /repo/$script >$script &&
		sha256sum $script >SHA256SUMS"
}

server_pid() { on_server 'systemctl show -p MainPID --value ur-vpn-server'; }

# Not every image has ping, so ask each end. The status file refreshes every 10s.
server_sees_client() {
	on_server "for i in \$(seq 1 90); do grep -q '^CLIENT_LIST,client1,' $SERVER_STATUS && exit 0; sleep 1; done; exit 1"
}

client_says_connected() {
	on_client 'for i in $(seq 1 90); do ur-vpn status | grep -q "VPN: connected" && exit 0; sleep 1; done; exit 1'
}

test_update() {
	local update='UR_VPN_RELEASE_URL=file:///tmp/release ur-vpn update'
	local pid output

	check_output "server starts on the dev version" "$(on_server 'ur-vpn version')" "dev"

	publish_release "$SERVER" server.sh v9.0.0
	pid=$(server_pid)
	output=$(on_server "$update" 2>&1)
	check_output "update installs the new release" "$output" "Updated to v9.0.0"
	check_output "the command is the new version" "$(on_server 'ur-vpn version')" "v9.0.0"
	if [[ $(server_pid) == "$pid" ]]; then ok "nothing changed, so clients were not disturbed"; else bad "update restarted the service for no reason"; fi

	check_output "update knows when it is up to date" "$(on_server "$update" 2>&1)" "Already on the latest"

	on_server 'printf "# changed after the checksum\n" >>/tmp/release/server.sh'
	check "update rejects a tampered release" on_server "! $update"
	check_output "a rejected release changes nothing" "$(on_server 'ur-vpn version')" "v9.0.0"

	publish_release "$SERVER" server.sh v9.0.1 's/^verb 3$/verb 4/'
	check "update applies a changed config" on_server "$update"
	check "the new config is in place" on_server 'grep -q "^verb 4$" /etc/openvpn/server/ur-vpn/server.conf'
	check "the service came back after the restart" on_server 'systemctl is-active --quiet ur-vpn-server'
	check "the client reconnected by itself" server_sees_client

	publish_release "$SERVER" server.sh v9.0.2 's/^verb 3$/no-such-option yes/'
	check "update reports a release that will not start" on_server "! $update"
	check_output "a failed update goes back to the old command" "$(on_server 'ur-vpn version')" "v9.0.1"
	check "a failed update goes back to the old config" on_server 'grep -q "^verb 4$" /etc/openvpn/server/ur-vpn/server.conf'
	check "a failed update leaves the service running" on_server 'systemctl is-active --quiet ur-vpn-server'
	check "the client survives a failed update" server_sees_client

	publish_release "$CLIENT" client.sh v9.0.0
	check_output "client update installs the new release" "$(on_client "$update" 2>&1)" "Updated from dev to v9.0.0"
	check_output "the client command is the new version" "$(on_client 'ur-vpn version')" "v9.0.0"
	check "client update leaves the VPN connected" on_client 'ur-vpn status | grep -q "VPN: connected"'
	on_client 'printf "# changed after the checksum\n" >>/tmp/release/client.sh'
	check "client update rejects a tampered release" on_client "! $update"
}

test_service_commands() {
	local pid

	check "server stop succeeds" on_server 'ur-vpn stop'
	check "a stopped server is not running" on_server '! systemctl is-active --quiet ur-vpn-server'
	check "a stopped server stays off at boot" on_server '! systemctl is-enabled --quiet ur-vpn-server'
	check "status says the server is stopped" on_server 'ur-vpn status | grep -q stopped'
	check "stop removes the firewall rules" on_server '
		command -v iptables >/dev/null || exit 0
		! iptables -w 5 -S 2>/dev/null | grep -q UR_VPN'
	check "managing clients does not wake a stopped server" on_server '
		ur-vpn add temp && ur-vpn revoke temp && ! systemctl is-active --quiet ur-vpn-server'

	check "server start succeeds" on_server 'ur-vpn start'
	check "a started server is running" on_server 'systemctl is-active --quiet ur-vpn-server'
	check "a started server is back on at boot" on_server 'systemctl is-enabled --quiet ur-vpn-server'
	check_output "starting it twice is harmless" "$(on_server 'ur-vpn start' 2>&1)" "Already running"
	check "the client reconnected after start" server_sees_client

	pid=$(server_pid)
	check "server restart succeeds" on_server 'ur-vpn restart'
	if [[ $(server_pid) != "$pid" ]]; then ok "restart replaced the process"; else bad "restart did not replace the process"; fi
	check "the client reconnected after restart" server_sees_client

	check "client stop succeeds" on_client 'ur-vpn stop'
	check "a stopped client is disconnected" on_client 'ur-vpn status | grep -q "VPN: not connected"'
	check "a stopped client stays off at boot" on_client '! systemctl is-enabled --quiet ur-vpn-client'
	check "client start succeeds" on_client 'ur-vpn start'
	check "a started client connects" client_says_connected
	check "a started client is back on at boot" on_client 'systemctl is-enabled --quiet ur-vpn-client'
	check "client restart succeeds" on_client 'ur-vpn restart'
	check "a restarted client connects" client_says_connected
}

test_client_management() {
	check "ur-vpn add creates a client" on_server 'ur-vpn add phone'
	check "rejects unsafe client names" on_server '! ur-vpn add "../../evil"'
	check "--raw prints a full .ovpn" on_server 'ur-vpn show phone --raw | grep -q "<tls-crypt"'

	check "ur-vpn revoke succeeds" on_server 'ur-vpn revoke client1'
	check "ur-vpn list shows it revoked" on_server 'ur-vpn list | grep -E "client1 +revoked"'
	sleep 25
	check "revoked client is refused" on_server "! grep -q '^CLIENT_LIST,client1,' $SERVER_STATUS"
}

test_removal() {
	check "client off restores DNS" on_client 'ur-vpn off; ! grep -q "nameserver 9.9.9.9" /etc/resolv.conf'
	check "client remove cleans up" on_client 'ur-vpn remove; [ ! -e /usr/local/bin/ur-vpn ] && [ ! -e /etc/openvpn/client/ur-vpn.conf ]'

	check "server uninstall succeeds" on_server 'ur-vpn uninstall --yes'
	check "no firewall chains left behind" on_server '
		command -v iptables >/dev/null || exit 0
		! iptables -w 5 -S 2>/dev/null | grep -q UR_VPN && ! iptables -w 5 -t nat -S 2>/dev/null | grep -q UR_VPN'
	check "no files left behind" on_server '[ ! -e /etc/ur-vpn ] && [ ! -e /etc/openvpn/server/ur-vpn ] && [ ! -e /usr/local/bin/ur-vpn ]'
}

readonly PHASES="test_server_install test_client_install test_tunnel test_rerun test_update test_service_commands test_client_management test_removal"

run_phases() {
	local image=$1 phase
	docker network create "$NETWORK" >/dev/null
	if ! prepare_image "$image"; then
		bad "could not prepare $image"
		return
	fi
	release_disk_space
	if ! start_node "$SERVER"; then
		bad "server container failed to start"
		return
	fi
	# shellcheck disable=SC2086 # CLIENT_ARGS is a list of docker flags
	if ! start_node "$CLIENT" ${CLIENT_ARGS:-}; then
		bad "client container failed to start"
		return
	fi
	SERVER_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NETWORK\").IPAddress}}" "$SERVER")

	for phase in $PHASES; do
		if (($(free_mb) < MIN_FREE_MB)); then
			bad "stopped before $phase: only $(free_mb) MB free on the host"
			return
		fi
		"$phase"
		if [[ $phase == test_server_install && -z $PASTE_BLOCK ]]; then
			bad "stopped: the server printed no block for the client to paste"
			return
		fi
	done
}

test_image() {
	local image=$1 failed_before=$failed image_was_here=no
	printf '\n=== %s (server: %s)\n' "$image" "${SERVER_ENV:-defaults}"

	if (($(free_mb) < MIN_FREE_MB)); then
		bad "skipped: only $(free_mb) MB free on the host"
		return
	fi
	if docker image inspect "$image" >/dev/null 2>&1; then image_was_here=yes; fi

	teardown
	run_phases "$image"

	if [[ $failed -ne $failed_before && ${KEEP:-0} == 1 ]]; then
		printf '  KEEP=1: containers left running (%s, %s)\n' "$SERVER" "$CLIENT"
		return
	fi
	teardown
	# Only delete base images this run downloaded.
	if [[ $image_was_here == no ]]; then
		docker rmi "$image" >/dev/null 2>&1
	fi
	release_disk_space
	printf '  host disk free: %s MB\n' "$(free_mb)"
}

if (($# == 0)); then
	set -- ubuntu:24.04
fi
for image in "$@"; do
	test_image "$image"
done
printf '\n%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
