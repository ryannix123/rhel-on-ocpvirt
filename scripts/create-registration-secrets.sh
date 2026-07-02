#!/bin/bash
# create-registration-secrets.sh
#
# Renders cloud-init userdata (with the Satellite registration script
# embedded) for each RHEL major and stores it as a Secret in the target
# namespace. VirtualMachines reference these via cloudInitNoCloud.secretRef,
# so the Satellite JWT never appears in a VM manifest or Git.
#
# Usage:
#   export SATELLITE_URL=https://satellite.example.com
#   export SATELLITE_ORG_ID=1
#   export SATELLITE_LOCATION_ID=2
#   export SATELLITE_REG_JWT='eyJhbGciOi...'
#   ./scripts/create-registration-secrets.sh [namespace]
#
# Activation keys default to ak-rhel-<major>; override with
# ACTIVATION_KEY_RHEL7/8/9/10 env vars.

set -euo pipefail

NAMESPACE="${1:-rhel-fleet}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REG_SCRIPT="${SCRIPT_DIR}/satellite-register.sh"

for var in SATELLITE_URL SATELLITE_ORG_ID SATELLITE_REG_JWT; do
    if [ -z "${!var:-}" ]; then
        echo "FATAL: ${var} is not set" >&2
        exit 1
    fi
done
[ -r "${REG_SCRIPT}" ] || { echo "FATAL: ${REG_SCRIPT} not found" >&2; exit 1; }

# base64 the script so YAML indentation can never mangle it
if base64 --help 2>&1 | grep -q -- -w; then
    SCRIPT_B64=$(base64 -w0 "${REG_SCRIPT}")   # GNU (Linux)
else
    SCRIPT_B64=$(base64 -i "${REG_SCRIPT}" | tr -d '\n')  # macOS
fi

oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || oc create namespace "${NAMESPACE}"

for MAJOR in 7 8 9 10; do
    AK_VAR="ACTIVATION_KEY_RHEL${MAJOR}"
    ACTIVATION_KEY="${!AK_VAR:-ak-rhel-${MAJOR}}"

    USERDATA=$(mktemp)
    cat > "${USERDATA}" <<EOF
#cloud-config
write_files:
  - path: /etc/satellite-register/satellite-register.sh
    permissions: '0750'
    encoding: b64
    content: ${SCRIPT_B64}
  - path: /etc/sysconfig/satellite-register
    permissions: '0600'
    content: |
      SATELLITE_URL=${SATELLITE_URL}
      ORG_ID=${SATELLITE_ORG_ID}
      LOCATION_ID=${SATELLITE_LOCATION_ID:-}
      ACTIVATION_KEY=${ACTIVATION_KEY}
      REG_JWT=${SATELLITE_REG_JWT}
runcmd:
  - [/etc/satellite-register/satellite-register.sh]
EOF

    oc create secret generic "cloudinit-rhel${MAJOR}" \
        --namespace "${NAMESPACE}" \
        --from-file=userdata="${USERDATA}" \
        --dry-run=client -o yaml | oc apply -f -
    rm -f "${USERDATA}"
    echo "Secret cloudinit-rhel${MAJOR} applied (activation key: ${ACTIVATION_KEY})"
done

echo
echo "Done. VMs in namespace '${NAMESPACE}' can now reference:"
echo "  cloudInitNoCloud: { secretRef: { name: cloudinit-rhel<major> } }"
