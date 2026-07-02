#!/bin/bash
# satellite-firstboot.sh
#
# Executed by satellite-register.service (systemd oneshot) on first boot.
# Registers this host to Satellite using the global registration endpoint.
# Config is sourced from /etc/sysconfig/satellite-register, baked into the
# image at compose time by the hosted Image Builder.
#
# On success it drops /var/lib/satellite-register.done, which disarms the
# systemd unit (ConditionPathExists). On failure the unit simply runs again
# on the next boot -- handy if the VM first boots somewhere Satellite isn't
# reachable yet.
#
# Works on RHEL 8, 9, and 10 against Satellite 6.19.

set -o pipefail

CONF=/etc/sysconfig/satellite-register
STAMP=/var/lib/satellite-register.done
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

# Already registered? (cloned from a registered template, manual register, etc.)
if subscription-manager identity >/dev/null 2>&1; then
    echo "Host already registered; disarming unit."
    touch "${STAMP}"
    exit 0
fi

# Wait for Satellite to be reachable (up to ~5 minutes this boot).
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
    echo "Satellite unreachable after 5 minutes; will retry on next boot."
    echo "Or run manually: /etc/satellite-register/satellite-register.sh"
    exit 1
fi

# Build the global registration URL. Satellite 6.19 renders a shell script
# tailored to this org/activation key; piping it to bash installs the
# katello-server-ca cert and runs subscription-manager register.
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

if [ "${rc}" -eq 0 ]; then
    echo "Registration succeeded:"
    subscription-manager identity
    touch "${STAMP}"
    # Scrub the JWT now that it's no longer needed on this host.
    sed -i 's/^REG_JWT=.*/REG_JWT=redacted-after-registration/' "${CONF}"
else
    echo "Registration failed after 3 attempts; will retry on next boot."
fi

echo "=== $(date -Is) satellite-register finished (rc=${rc}) ==="
exit "${rc}"
