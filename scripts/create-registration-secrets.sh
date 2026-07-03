#!/bin/bash
# create-registration-secrets.sh
#
# Renders cloud-init userdata (with the Satellite registration script
# embedded) for each RHEL major and stores it as a Secret in the target
# namespace. VirtualMachines reference these via cloudInitNoCloud.secretRef,
# so the Satellite JWT never appears in a VM manifest or Git.
#
# Usage (run from whatever project you want the VMs in):
#   export SATELLITE_URL=https://satellite.example.com
#   export SATELLITE_ORG_ID=1
#   export SATELLITE_LOCATION_ID=2
#   export SATELLITE_REG_JWT='eyJhbGciOi...'
#   ./scripts/create-registration-secrets.sh [namespace]
#
# Defaults to your current project (oc project -q). Secrets are
# namespace-scoped, so re-run this once per namespace you deploy VMs into.
#
# Activation keys default to ak-rhel-<major>; override with
# ACTIVATION_KEY_RHEL7/8/9/10 env vars.
#
# Login credentials (RHEL cloud images have NO default credentials):
#   CLOUD_USER      - login user to create (default: cloud-user)
#   SSH_PUBKEY      - public key for that user (recommended)
#   CLOUD_PASSWORD  - password for that user (optional; console logins)
# At least one of SSH_PUBKEY / CLOUD_PASSWORD should be set or you will
# not be able to log into the VMs.
#
# No-DNS environments:
#   SATELLITE_IP    - if your Satellite hostname is not resolvable by DNS
#                     (e.g. homelab with /etc/hosts only), set this and an
#                     /etc/hosts entry is added to every VM via cloud-init.

set -euo pipefail

NAMESPACE="${1:-$(oc project -q)}"
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

oc get namespace "${NAMESPACE}" >/dev/null || exit 1
echo "Target namespace: ${NAMESPACE}"

CLOUD_USER="${CLOUD_USER:-cloud-user}"
if [ -z "${SSH_PUBKEY:-}" ] && [ -z "${CLOUD_PASSWORD:-}" ]; then
    echo "WARN: neither SSH_PUBKEY nor CLOUD_PASSWORD set -- VMs will register" >&2
    echo "      to Satellite but you won't be able to log into them." >&2
fi

# Login block for the cloud-init userdata
LOGIN_BLOCK="user: ${CLOUD_USER}"
if [ -n "${CLOUD_PASSWORD:-}" ]; then
    LOGIN_BLOCK="${LOGIN_BLOCK}
password: ${CLOUD_PASSWORD}
chpasswd: { expire: False }"
fi
if [ -n "${SSH_PUBKEY:-}" ]; then
    LOGIN_BLOCK="${LOGIN_BLOCK}
ssh_authorized_keys:
  - ${SSH_PUBKEY}"
fi

# No-DNS support: prepend an /etc/hosts entry before registration runs
SATELLITE_HOST=$(echo "${SATELLITE_URL}" | sed -e 's|^https\{0,1\}://||' -e 's|[:/].*$||')
HOSTS_CMD=""
if [ -n "${SATELLITE_IP:-}" ]; then
    HOSTS_CMD="  - [sh, -c, \"grep -q '${SATELLITE_HOST}' /etc/hosts || echo '${SATELLITE_IP} ${SATELLITE_HOST}' >> /etc/hosts\"]
"
    echo "Adding hosts entry to userdata: ${SATELLITE_IP} ${SATELLITE_HOST}"
fi

for MAJOR in 7 8 9 10; do
    AK_VAR="ACTIVATION_KEY_RHEL${MAJOR}"
    ACTIVATION_KEY="${!AK_VAR:-ak-rhel-${MAJOR}}"

    USERDATA=$(mktemp)
    cat > "${USERDATA}" <<EOF
#cloud-config
${LOGIN_BLOCK}
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
${HOSTS_CMD}  - [/etc/satellite-register/satellite-register.sh]
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
