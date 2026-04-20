#!/bin/sh
# RavenOS PI5 — periodic Wi-Fi guard.
#
# Two jobs:
#   1. While hostapd is running (fallback AP mode), NM tends to flip the Wi-Fi
#      iface back to "managed" and kill the AP within seconds. Re-assert
#      "unmanaged" on whichever iface is in AP mode.
#   2. If hostapd is NOT running *and* no wireless iface has a usable STA IP,
#      the Wi-Fi is orphaned (closed browser mid-wizard, failed nmcli join,
#      out-of-range Wi-Fi, etc.). Re-run autohotspotN so the RavenOS AP comes
#      back automatically — user never needs to power-cycle to recover.
#
# A 60-second cool-down (/run/ravenos-ap-recovery.stamp) keeps recovery from
# thrashing while autohotspotN is still bringing the AP up.
set -u

command -v nmcli >/dev/null 2>&1 || exit 0
systemctl is-active --quiet NetworkManager 2>/dev/null || exit 0

# ── Case 1: hostapd active → keep AP iface unmanaged ─────────────────────
if systemctl is-active --quiet hostapd 2>/dev/null; then
	for w in $(iw dev 2>/dev/null | awk '/Interface /{print $2}'); do
		if iw "$w" info 2>/dev/null | grep -q "type AP"; then
			nmcli device set "$w" managed no 2>/dev/null || true
		fi
	done
	exit 0
fi

# ── Case 2: hostapd inactive → check if any iface is a usable STA ────────
STA_HAS_IP=0
for w in $(iw dev 2>/dev/null | awk '/Interface /{print $2}'); do
	# managed == STA role in iw's terminology
	if iw "$w" info 2>/dev/null | grep -q "type managed"; then
		if ip -4 addr show dev "$w" 2>/dev/null | grep -q "inet "; then
			STA_HAS_IP=1
			break
		fi
	fi
done

# STA is up and has an IP → leave everything alone.
[ "$STA_HAS_IP" -eq 1 ] && exit 0

# ── Orphaned: no AP, no STA IP. Recover via autohotspotN with cool-down ──
COOLDOWN=/run/ravenos-ap-recovery.stamp
now=$(date +%s)
last=0
[ -r "$COOLDOWN" ] && last=$(cat "$COOLDOWN" 2>/dev/null || echo 0)
if [ $((now - last)) -lt 60 ]; then
	exit 0
fi
echo "$now" > "$COOLDOWN"

if [ -x /usr/bin/autohotspotN ]; then
	logger -t ravenos-ap-guard "wlan orphaned (no AP, no STA IP) — invoking autohotspotN"
	/usr/bin/autohotspotN >/var/log/ravenos-ap-guard-recovery.log 2>&1 || true
fi

exit 0
