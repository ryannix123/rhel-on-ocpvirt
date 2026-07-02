#!/bin/bash
# satellite-register.sh
#
# Delivered to each VM via cloud-init (write_files) and executed once by
# cloud-init runcmd on first boot. Registers the VM to Satellite using the
# global registration endpoint, then installs qemu-guest-agent from
# Satellite content so OpenShift Virtualization gets full guest visibility.
#
# Config is written by cloud-init to /etc/sysconfig/satellite-register.
# Works on RHEL 7, 8, 9, and 10 against Satellite 6.19.

set -o pipefail

CONF=/etc/sysconfig/satellite-register
LOG=/var/log/satellite-register.log
exec >>"${LOG}" 2>&1
echo "=== $(date -Is) satellite-register starting ==="

if [ ! -r "${CONF}" ]; then
    echo "FATAL: ${CONF} not found or unreadable"
    exit 1
fi
# shellcheck source=/dev/null
source "${CONF}"

for var in SATELLITE_URL ORG_ID ACTIVATION_KEY REG_JWT; do
    if [ -z "${!var}" ]; then
        echo "FATAL: ${var} is not set in ${CONF}"
        exit 1
    fi
done

if subscription-manager identity >/dev/null 2>&1; then
    echo "Host already registered; nothing to do."
    exit 0
fi

# Wait for Satellite to be reachable (up to ~5 minutes).
# -k because the Katello server CA isn't trusted yet; the generated
# registration script installs it as part of registration.
echo "Waiting for ${SATELLITE_URL} to become reachable..."
reachable=0
for i in $(seq 1 30); do
    if curl -skf --connect-timeout 5 "${SATELLITE_URL}/pub/" >/dev/null; then
        reachable=1
        break
    fi
    sleep 10
done
if [ "${reachable}" -ne 1 ]; then
    echo "FATAL: Satellite unreachable after 5 minutes."
    echo "Re-run manually: /etc/satellite-register/satellite-register.sh"
    exit 1
fi

# Satellite 6.19 renders a shell script tailored to this org/activation
# key; piping it to bash installs the katello-server-ca cert and runs
# subscription-manager register.
PARAMS="activation_keys=${ACTIVATION_KEY}"
PARAMS="${PARAMS}&organization_id=${ORG_ID}"
[ -n "${LOCATION_ID}" ] && PARAMS="${PARAMS}&location_id=${LOCATION_ID}"
PARAMS="${PARAMS}&update_packages=false"
PARAMS="${PARAMS}&setup_insights=false"
PARAMS="${PARAMS}&setup_remote_execution=true"
PARAMS="${PARAMS}&ignore_subman_errors=true"

rc=1
for attempt in 1 2 3; do
    echo "Registration attempt ${attempt}..."
    if curl -skS "${SATELLITE_URL}/register?${PARAMS}" \
        -H "Authorization: Bearer ${REG_JWT}" | bash; then
        if subscription-manager identity >/dev/null 2>&1; then
            rc=0
            break
        fi
    fi
    sleep 30
done

if [ "${rc}" -ne 0 ]; then
    echo "FATAL: registration failed after 3 attempts. See above."
    echo "=== $(date -Is) satellite-register finished (rc=${rc}) ==="
    exit "${rc}"
fi

echo "Registration succeeded:"
subscription-manager identity

# Scrub the JWT now that it's no longer needed on this host.
sed -i 's/^REG_JWT=.*/REG_JWT=redacted-after-registration/' "${CONF}"

# qemu-guest-agent: gives OpenShift Virtualization IP reporting, graceful
# shutdown, and consistent snapshots. Installed from Satellite content,
# which is why this runs after registration.
PKG_MGR=yum
command -v dnf >/dev/null 2>&1 && PKG_MGR=dnf
if ! rpm -q qemu-guest-agent >/dev/null 2>&1; then
    echo "Installing qemu-guest-agent via ${PKG_MGR}..."
    "${PKG_MGR}" -y install qemu-guest-agent || \
        echo "WARN: qemu-guest-agent install failed (check activation key repos)"
fi
systemctl enable --now qemu-guest-agent 2>/dev/null || true

echo "=== $(date -Is) satellite-register finished (rc=0) ==="
exit 0
