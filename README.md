# Satellite-Ready RHEL qcow2 Builder (Hosted Image Builder)

Composes RHEL 8, 9, and 10 guest images (qcow2) using **Red Hat's hosted
Image Builder** (console.redhat.com), driven from GitHub Actions, with a
firstboot systemd unit baked in that auto-registers each VM to
**Satellite 6.19**.

## How it works

```
GitHub Actions (ubuntu-latest, free tier)
  ├─ Authenticate to console.redhat.com (service account or offline token)
  ├─ POST /api/image-builder/v1/compose
  │    distribution: rhel-8|9|10, image_type: guest-image
  │    customizations.files:
  │      /etc/satellite-register/satellite-register.sh
  │      /etc/sysconfig/satellite-register        (URL, org, AK, JWT)
  │      /etc/systemd/system/satellite-register.service
  │    customizations.services.enabled: [satellite-register]
  ├─ Poll /composes/{id} until success (Red Hat builds it via osbuild)
  ├─ Download the presigned qcow2 URL immediately
  └─ zstd-compress and upload as workflow artifact

First boot on YOUR network
  └─ satellite-register.service (oneshot, network-online, stamp-guarded)
       curls https://satellite.example.com/register?activation_keys=...
       with Bearer JWT, pipes generated script to bash
       → CA installed, subscription-manager registered, host in Satellite
```

**Your Satellite never needs to be publicly reachable.** Neither the hosted
Image Builder nor GitHub ever contacts it — `satellite.example.com` only has
to resolve on the network where the VM boots. If a VM boots somewhere
Satellite *isn't* reachable, the unit fails softly and re-arms for the next
boot (a stamp file at `/var/lib/satellite-register.done` disarms it after
success).

## One-time setup

### 1. console.redhat.com credentials (pick one)

**Preferred — service account:** console.redhat.com → Identity & Access
Management → Service Accounts → create one, grant it Image Builder access
via a group/role. Store as secrets `RH_SA_CLIENT_ID` and
`RH_SA_CLIENT_SECRET`. (The workflow requests `scope=api.console`.)

**Fallback — offline token:** generate at
<https://access.redhat.com/management/api>, store as `RH_OFFLINE_TOKEN`.
Offline tokens expire after 30 days of *inactivity*; the monthly cron keeps
it warm. Red Hat is steering console API auth toward service accounts, so
prefer that.

### 2. Satellite registration token (JWT)

Satellite 6.19: **Hosts → Register Host**, set a token lifetime long enough
to cover the deployment life of your images, generate, and copy the JWT
from the `Authorization: Bearer` header of the generated command (or use
`hammer host-registration generate-command`). Store as `SATELLITE_REG_JWT`.

**Security note:** the JWT and activation key are sent to Red Hat's hosted
service inside the compose request and embedded in the image (briefly
staged on Red Hat's S3 behind a presigned URL). The JWT can only register
hosts, but treat artifacts as internal, use a dedicated Satellite user with
a minimal registration role, and pick a sane token lifetime. The firstboot
script scrubs the JWT from the guest after successful registration.

### 3. Repository variables and activation keys

| Variable | Example |
|---|---|
| `SATELLITE_URL` | `https://satellite.example.com` (internal DNS is fine) |
| `SATELLITE_ORG_ID` | `1` |
| `SATELLITE_LOCATION_ID` | `2` |
| `ACTIVATION_KEY_RHEL8/9/10` | *(optional override)* |

Default activation key convention: `ak-rhel-8`, `ak-rhel-9`, `ak-rhel-10`,
each mapped in Satellite to the right lifecycle environment, content view,
and host group.

## Running it

Trigger via **Actions → Run workflow**, or let the monthly cron pick up new
point releases. Composes typically take 10–30 minutes on Red Hat's side;
the workflow polls for up to an hour and downloads the presigned URL
immediately (hosted-builder images expire quickly, so the GitHub artifact
is your durable copy). Artifacts land as
`rhel-<N>-satellite-YYYYMMDD.qcow2.zst` — decompress with `zstd -d` and
import into libvirt, OpenShift Virtualization (CDI), or Proxmox.

On first boot check `/var/log/satellite-register.log` and
`systemctl status satellite-register`.

## Design notes

- **Why hosted Image Builder?** Real compose-time customization (packages,
  partitioning, OpenSCAP, kernel args can all be added to the request),
  Red Hat's infrastructure does the building, and the workflow stays on
  free `ubuntu-latest` runners doing nothing but API calls. Extending this
  repo to also emit AMIs, Azure VHDs, or VMware OVAs from the same
  customizations is a one-block change to `image_requests`.
- **Files customization lives under `/etc`** — the hosted builder restricts
  custom file paths, hence `/etc/satellite-register/` rather than
  `/usr/local/sbin`. The systemd unit is enabled via
  `customizations.services.enabled`.
- **Why not the builder's native registration?** Image Builder's built-in
  registration option targets Red Hat's own RHSM/Insights (console.redhat.com),
  not an on-prem Satellite. Newer console UI versions have grown a Satellite
  registration option — if your tenant exposes it in the API schema, it can
  replace the hand-rolled files customization here; the firstboot approach
  works regardless of version.
- **Access tokens are short-lived (~15 min)** while composes take 30+,
  so the workflow fetches a fresh token per API call rather than reusing one.
- **Verify field names on first run:** the compose API schema is documented
  at console.redhat.com/docs/api/image-builder. If `POST /compose` rejects
  the request, diff against `GET /distributions` output and the current
  schema — the jq blocks are easy to adjust.
