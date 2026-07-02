# RHEL Fleet on OpenShift Virtualization, Registered to Satellite

Runs RHEL 7, 8, 9, and 10 VMs in a single namespace on OpenShift
Virtualization, each auto-registering to **Satellite 6.19** on first boot.

**No image pipeline.** OpenShift Virtualization already maintains
auto-updating RHEL golden images (DataImportCron boot sources in
`openshift-virtualization-os-images`), so RHEL 8/9/10 need zero image
building. Registration happens via **cloud-init at VM creation** — the
Satellite JWT lives in a Secret in your cluster and never touches an image,
a registry, or an external service.

## How it works

```
oc apply VM manifest
  ├─ dataVolumeTemplate clones the boot source
  │    rhel8/9/10 → built-in DataSources (auto-updated by DataImportCron)
  │    rhel7      → local DataSource from a one-time 7.9 upload
  └─ cloudInitNoCloud.secretRef → cloudinit-rhel<N> Secret
       write_files: registration script + config
       runcmd (runs once per instance):
         curl https://satellite.example.com/register?... | bash
         → CA installed, subscription-manager registered
         → qemu-guest-agent installed from Satellite content
```

Internal-only Satellite DNS is fine: VMs use the pod network
(masquerade), egress through your SNO node onto your LAN, and resolve
`satellite.example.com` via the node's upstream DNS.

## Repo layout

```
rhel-ocpvirt-satellite/
├── README.md
├── manifests/
│   ├── vm-rhel7.yaml        # DataSource (local) + VirtualMachine
│   ├── vm-rhel8.yaml
│   ├── vm-rhel9.yaml
│   └── vm-rhel10.yaml
└── scripts/
    ├── satellite-register.sh              # runs inside each VM via cloud-init
    └── create-registration-secrets.sh     # renders/applies cloudinit-rhel<N> Secrets
```

## Setup

### 1. Satellite prerequisites

- Activation keys `ak-rhel-7` … `ak-rhel-10`, each mapped to the right
  lifecycle environment / content view / host group. Make sure each
  content view carries the OS repos **including qemu-guest-agent** (BaseOS
  for 8/9/10, `rhel-7-server-rpms` for 7) so the script can install it.
- RHEL 7 clients need **ELS** repos synced if you want updates; 7.9
  registers fine either way.
- A registration JWT: **Hosts → Register Host**, pick a token lifetime,
  copy the Bearer token from the generated command.

### 2. Create the namespace and cloud-init Secrets

```bash
export SATELLITE_URL=https://satellite.example.com
export SATELLITE_ORG_ID=1
export SATELLITE_LOCATION_ID=2
export SATELLITE_REG_JWT='eyJhbGciOi...'
./scripts/create-registration-secrets.sh rhel-fleet
```

This creates Secrets `cloudinit-rhel7/8/9/10`, each containing complete
cloud-init userdata (registration script + per-version activation key).
Rotating the JWT = re-run the script. Existing VMs are unaffected; new VMs
pick up the new Secret content at creation.

### 3. One-time RHEL 7 base image upload

Download `rhel-server-7.9-x86_64-kvm.qcow2` from access.redhat.com, then:

```bash
virtctl image-upload dv rhel7-base \
  --namespace rhel-fleet \
  --size 15Gi \
  --image-path ./rhel-server-7.9-x86_64-kvm.qcow2 \
  --insecure
```

7.9 is the final RHEL 7 release, so this never needs repeating.

### 4. Launch the fleet

```bash
oc apply -f manifests/
oc get vmi -n rhel-fleet -w
```

Each VM clones its boot source, boots, registers, and installs
qemu-guest-agent. Within a few minutes all four should appear in
Satellite under **Hosts → All Hosts**, and `oc get vmi` shows IPs once
the agent reports in.

Troubleshooting inside a guest: `/var/log/satellite-register.log`, or
re-run `/etc/satellite-register/satellite-register.sh` manually.
(Cloud-init runcmd executes once per instance; if registration failed,
manual re-run is the retry path.)

## Design notes

- **Why cloud-init Secrets instead of golden images with registration
  baked in?** Simpler (no pipeline), safer (JWT stays in-cluster, scrubbed
  from the guest after registration), and it composes with OCP Virt's
  auto-updated boot sources — you always boot the current RHEL point
  release without rebuilding anything.
- **instancetype/preference:** `u1.medium` + `rhel.<N>` cluster preferences
  set sane defaults. Don't add `domain.cpu`/`memory` alongside an
  instancetype — KubeVirt rejects the conflict. Scale up by swapping
  `u1.medium` for `u1.large`, etc.
- **RHEL 10 note:** boot sources for RHEL 10 require a current OCP Virt
  (4.19+). Your SNO node CPU (i9-12900) satisfies RHEL 10's x86-64-v3
  requirement; the default CPU passthrough on OCP Virt handles the rest.
- **RHEL 7 + Satellite 6.19:** registration via the global endpoint works
  on 7.9 (curl + subscription-manager, TLS 1.2). Confirm your Satellite
  version still ships RHEL 7 client repos if you need katello-host-tools.
- **More VMs:** copy a manifest, change the `name` fields — or template it
  with Kustomize/Helm when the fleet grows. The Secrets are per-version,
  shared by all VMs of that major.
