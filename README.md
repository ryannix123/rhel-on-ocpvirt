# RHEL qcow2 Image Builder

Ansible automation for building customized **Red Hat Enterprise Linux** qcow2
images with the osbuild-based `image-builder` CLI, ready to import into
**Proxmox** and register against **Red Hat Satellite**.

Builds RHEL **8, 9, and 10** (EUS by default). See [RHEL 7](#rhel-7) below for
why it isn't built here and what to do instead.

Based on the Red Hat Developer article:
[Build a Red Hat Enterprise Linux EUS image with image-builder CLI](https://developers.redhat.com/articles/2026/06/24/build-red-hat-enterprise-linux-eus-image-image-builder-cli).

---

## ⚠️ Security PSA — read before you commit

Before pushing anything to a public repo:

- **Never commit a real password hash.** The `admin_password_hash` in
  `build-images.yml` ships as a placeholder for `changeme`. Replace it for your
  builds, but do not commit your real hash — keep it in a vault file or pass it
  at runtime.
- **Never commit `org_id` or `activation_key`.** These are credentials. Pass
  them with `-e` at runtime or store them in an Ansible Vault file that is
  **git-ignored**.
- **Add a `.gitignore`** for vault files, rendered repo JSON/blueprints, and
  any `*.qcow2` output so secrets and large binaries never get tracked:

  ```gitignore
  # secrets
  vault.yml
  *.vault
  # generated build inputs
  repos/
  blueprints/
  # image output
  *.qcow2
  ```

- **Rotate the activation key** if one is ever exposed — treat a leaked key the
  same as a leaked password.

---

## What you get

- One qcow2 per RHEL version you target, with `qemu-guest-agent` baked in.
- An `admin` user in the `wheel` group.
- An optional firstboot systemd service that registers the system with
  subscription-manager and pins it to the matching **EUS** release and repos.
- All build inputs (repo definitions, blueprints) generated from templates, so
  adding a version is a one-line change.

---

## Repository layout

```
.
├── build-images.yml              # main playbook
├── inventory.ini                 # build host inventory
├── Containerfile.containerdisk   # wraps a qcow2 into a KubeVirt containerDisk
├── templates/
│   ├── rhel-repos.json.j2         # per-version CDN repo definition
│   └── blueprint.toml.j2          # per-version image blueprint
├── tekton/
│   ├── pipeline.yaml              # build → wrap → push-to-Quay pipeline
│   └── pipelinerun-example.yaml   # trigger a build for one version
└── manifests/
    └── vm-from-containerdisk.yaml # boot a VM from the Quay artifact
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **Build host** | A RHEL **9.x or 10.x** machine. The playbook asserts this. |
| **Subscription** | The build host must be registered (`subscription-manager` or `rhc`) with access to the EUS content you're building. |
| **Ansible** | 2.14+ on your control machine (or run locally on the build host). |
| **Packages** | The playbook installs `image-builder` and `qemu-img` for you. |
| **Disk space** | Each build needs several GB of scratch space in the workspace. |

> The `image-builder` CLI used here **cannot build RHEL 7** — it's RHEL 8+ only.

---

## Where do I run what?

**The image build must run on a RHEL 9/10 host.** `image-builder` depends on
osbuild and entitled subscription content, which exist only on a registered
RHEL machine — it cannot run on macOS or on an unsubscribed Linux box. The
easiest builder is a small RHEL VM on **Proxmox** or **OpenShift
Virtualization**, registered with `subscription-manager`. You drive everything
else from your workstation over SSH.

| Command / step | Run it on | Why |
|---|---|---|
| `git`, editing files | **Your workstation** (Mac/Linux) | Normal dev loop. |
| `openssl passwd -6` (generate admin hash) | **Your workstation** | macOS/Linux both have `openssl`. Pipe to `pbcopy` on Mac. |
| `ssh` into the builder | **Your workstation → builder** | You operate the builder remotely. |
| `ansible-playbook ... build-images.yml` | **RHEL 9/10 builder** | This invokes `image-builder` — RHEL-only. |
| `oc` / `tkn` / `virtctl` (cluster, pipeline, VMs) | **Your workstation** | Talk to OpenShift remotely. |
| `oras pull` (fetch qcow2 for Proxmox) | **Your workstation** or Proxmox host | Just downloads the artifact. |
| `qm importdisk` (Proxmox import) | **Proxmox host** | Proxmox CLI lives there. |

> **About `pbcopy`:** it's a macOS-only convenience for copying command output
> to your clipboard. **None of this repo's commands require it** — they write
> files and push images, not clipboard text. The only place it appears is the
> optional password-hash step, which you run on your Mac anyway. On a Linux
> builder the equivalent would be `xclip -selection clipboard` or `wl-copy`,
> but you rarely need it here since you're working over SSH with file output.

### Typical flow across machines

```text
┌─ Your Mac ───────────────────────────────────────────────┐
│  git clone / edit                                         │
│  openssl passwd -6 | pbcopy   → paste into build-images.yml│
│  ssh admin@rhel-builder ──────────────────────────────────┼──┐
└───────────────────────────────────────────────────────────┘  │
                                                                ▼
┌─ RHEL 9/10 builder (Proxmox or OpenShift Virt VM) ────────────┐
│  ansible-playbook -i inventory.ini build-images.yml ...        │
│  → produces output/rhel-<ver>-x86_64.qcow2                     │
└────────────────────────────────────────────────────────────────┘
                                                                ▲
┌─ Your Mac ──────────────────────────────────────────────────┐ │
│  oc apply -f manifests/vm-from-containerdisk.yaml  (OpenShift)│ │
│  oras pull ... ; scp to Proxmox ; qm importdisk    (Proxmox) ─┼─┘
└──────────────────────────────────────────────────────────────┘
```

> Running the Tekton pipeline instead? Then the build happens **inside the
> cluster** on an entitled RHEL builder node, and you only need `oc`/`tkn` from
> your workstation — no manual SSH. See
> [Pipeline: build once, store in Quay](#pipeline-build-once-store-in-quay-boot-anywhere).

---

## Quick start

### 1. Clone the repo

```bash
git clone https://github.com/<your-org>/rhel-image-builder.git
cd rhel-image-builder
```

### 2. Generate an admin password hash

The default hash in the playbook is literally `changeme`. Replace it. Run this
**on your workstation** (the `pbcopy` pipe is macOS; on Linux drop it or use
`xclip`):

```bash
openssl passwd -6 | pbcopy
```

Paste the result into `build-images.yml` (`admin_password_hash:`), or better,
keep it in a vault file and pass it at runtime.

### 3. Point the inventory at your build host

Edit `inventory.ini`. Use `localhost` if you're running on the build host
itself:

```ini
[build_host]
localhost ansible_connection=local
```

Or target a remote host:

```ini
[build_host]
rhel-builder.lab.local ansible_user=admin
```

### 4. Build the images

Build the defaults (8.10, 9.6, 10.2):

```bash
ansible-playbook -i inventory.ini build-images.yml
```

Build a specific set:

```bash
ansible-playbook -i inventory.ini build-images.yml \
  -e 'target_versions=["9.6","10.2"]'
```

Enable firstboot registration + EUS pinning (recommended for Satellite-managed
hosts):

```bash
ansible-playbook -i inventory.ini build-images.yml \
  -e org_id=YOUR_ORG_ID \
  -e activation_key=YOUR_ACTIVATION_KEY
```

> If you omit `org_id` and `activation_key`, the firstboot service is skipped
> entirely and the image boots unregistered.

### 5. Collect the output

Finished images land in:

```
/var/lib/image-builder-workspace/output/rhel-<ver>-x86_64.qcow2
```

---

## Importing into Proxmox

Copy the images to your Proxmox host:

```bash
scp /var/lib/image-builder-workspace/output/*.qcow2 \
  root@proxmox:/var/lib/vz/template/qcow/
```

Then import a disk into a VM (replace `<vmid>` and `<storage>`):

```bash
qm importdisk <vmid> /var/lib/vz/template/qcow/rhel-9.6-x86_64.qcow2 <storage>
```

Attach the imported disk, set it as the boot disk, and (optionally) convert the
VM to a template for cloning:

```bash
qm set <vmid> --scsi0 <storage>:vm-<vmid>-disk-0
qm set <vmid> --boot order=scsi0
qm template <vmid>
```

---

## Running on OpenShift Virtualization

[OpenShift Virtualization](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/virtualization/about)
(KubeVirt) runs these same qcow2 images as VMs alongside your containers. The
clean path is to import each qcow2 into a **DataVolume** (CDI) backed by a
PVC, then boot VMs from it. The example below uses
`virtctl image-upload` to push a local qcow2 into a PVC — no registry required.

### Prerequisites

- OpenShift Virtualization Operator installed and the `HyperConverged` CR
  deployed.
- The `virtctl` CLI (`oc get csv -n openshift-cnv` to confirm the version, then
  download the matching `virtctl`).
- A default storage class that supports the access mode you need
  (`ReadWriteMany` is required for live migration).

### 1. Upload the qcow2 into a PVC

`virtctl` handles the upload-proxy plumbing and creates the PVC for you:

```bash
virtctl image-upload dv rhel-96-golden \
  --size=20Gi \
  --image-path=/var/lib/image-builder-workspace/output/rhel-9.6-x86_64.qcow2 \
  --insecure
```

Repeat per version (`rhel-810-golden`, `rhel-10-golden`, etc.). Each becomes a
bootable DataVolume you can clone from.

### 2. (Optional) cloud-init for first boot

The blueprint already bakes in the `admin` user and the firstboot registration
service, so you may not need cloud-init at all. If you'd rather set the password
or inject keys at boot, define a cloud-init secret and reference it in the VM's
`volumes` (shown inline below).

### 3. Define a VirtualMachine

Save as `rhel-96-vm.yaml`. This clones the golden DataVolume so the source PVC
stays pristine, and enables the guest agent (already baked into the image).

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: rhel-96-vm
  namespace: vms
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/domain: rhel-96-vm
    spec:
      domain:
        cpu:
          cores: 2
        memory:
          guest: 4Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: rhel-96-vm-root
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              # Optional: image already has the admin user + firstboot service.
              # Use this only to override at boot.
              ssh_authorized_keys:
                - ssh-ed25519 AAAA... your-key
  dataVolumeTemplates:
    - metadata:
        name: rhel-96-vm-root
      spec:
        source:
          pvc:
            namespace: vms
            name: rhel-96-golden
        storage:
          resources:
            requests:
              storage: 20Gi
```

Apply it:

```bash
oc apply -f rhel-96-vm.yaml
```

### 4. Access and verify

```bash
# Watch it come up
oc get vm,vmi -n vms

# Serial console
virtctl console rhel-96-vm -n vms

# SSH (guest agent reports the IP once it's up)
virtctl ssh admin@rhel-96-vm -n vms
```

> **Golden image pattern:** keep the uploaded DataVolumes (`*-golden`) as
> read-only sources and always clone via `dataVolumeTemplates`. That gives you
> the same reusable-template workflow you'd get from `qm template` in Proxmox,
> and pairs naturally with Satellite for post-boot registration and
> content management.

---

## Pipeline: build once, store in Quay, boot anywhere

You can offload the whole build to **OpenShift Pipelines (Tekton)** and store
the result in **Quay**, so VMs are sourced from a versioned, centrally-managed
artifact instead of a qcow2 someone built on a laptop. That registry-as-source-
of-truth model *is* the supply-chain improvement story — the same posture
Satellite enforces for running hosts, applied to your golden images.

### How a qcow2 lives in Quay

A qcow2 is a VM disk, not a container image — so it can't go into Quay as-is.
The pipeline produces **two** artifacts from one build, and you choose how to
consume them:

| Artifact | What it is | Who consumes it |
|---|---|---|
| **containerDisk** (`...:9.6`) | qcow2 baked into a `FROM scratch` OCI image at `/disk/` | OpenShift Virt — boots directly, no download step |
| **raw qcow2** (`...-raw:9.6`) | the qcow2 pushed as a generic OCI artifact via `oras` | Proxmox — `oras pull`, then `qm importdisk` |

The containerDisk is the native path for OpenShift Virtualization. The raw
artifact exists so Proxmox (which can't boot from a registry) can still pull a
governed, versioned image instead of a loose file.

### ⚠️ Runner reality — read this first

`image-builder` needs **root, osbuild, and entitled subscription content**. It
**cannot** run on a generic unprivileged OpenShift worker. The `build-qcow2`
task is therefore `privileged: true` and assumes the node it lands on is a
**registered RHEL 9/10 builder** with entitlements available. Common patterns:

- A dedicated RHEL builder node, labeled and tainted, that this task tolerates.
- Entitlement certs mounted into the build pod (Insights / `etc-pki-entitlement`).
- A standalone RHEL builder VM running the playbook, with Tekton only handling
  the wrap-and-push stages.

Swap the placeholder builder image in `tekton/pipeline.yaml` (`build-qcow2`
task) for your entitled image before running.

### One-time setup

Create the two secrets the pipeline expects:

```bash
# Quay push credentials (a robot account token is ideal)
oc create secret docker-registry quay-auth \
  --docker-server=quay.io \
  --docker-username='ryan_nix+robot' \
  --docker-password='<robot-token>' \
  -n <pipeline-namespace>

# Subscription details baked into the firstboot service
oc create secret generic rhsm-activation \
  --from-literal=org_id='YOUR_ORG_ID' \
  --from-literal=activation_key='YOUR_ACTIVATION_KEY' \
  -n <pipeline-namespace>
```

Install the pipeline and tasks:

```bash
oc apply -f tekton/pipeline.yaml
```

### Run a build

Edit `tekton/pipelinerun-example.yaml` (version, Quay repo, git URL), then:

```bash
oc create -f tekton/pipelinerun-example.yaml
tkn pipelinerun logs -f --last   # follow it
```

Run one PipelineRun per RHEL version, or wire a trigger to loop over your
target set.

### Boot a VM from the Quay artifact

`manifests/vm-from-containerdisk.yaml` shows both consumption modes:

- **Option A — ephemeral containerDisk:** root disk pulled from Quay onto the
  node, ephemeral across re-creation. Fast, stateless, ideal for demos and
  scale-out.
- **Option B — persistent DataVolume:** CDI imports the registry image into a
  PVC once (`source: registry:`), root disk survives reboots. This is the
  golden-image "import once, clone many" pattern.

```bash
oc apply -f manifests/vm-from-containerdisk.yaml
```

### Pulling the raw artifact for Proxmox

```bash
oras pull quay.io/ryan_nix/rhel-containerdisk-raw:9.6
# → rhel-9.6-x86_64.qcow2 lands in the current dir, then:
scp rhel-9.6-x86_64.qcow2 root@proxmox:/var/lib/vz/template/qcow/
```

---

All variables live at the top of `build-images.yml`:

| Variable | Default | Purpose |
|---|---|---|
| `target_versions` | `["8.10","9.6","10.2"]` | Versions to build. |
| `arch` | `x86_64` | Target architecture. |
| `org_id` | `""` | Subscription org ID for firstboot registration. |
| `activation_key` | `""` | Activation key for firstboot registration. |
| `admin_password_hash` | `changeme` hash | SHA-512 hash from `openssl passwd -6`. |
| `work_dir` | `/var/lib/image-builder-workspace` | Build scratch space. |
| `output_dir` | `<work_dir>/output` | Where finished qcow2 files are copied. |

### Adding a version

Add the version string to `target_versions`. The playbook templates the repo
definition and blueprint automatically. EUS CDN paths are derived from the
version; a `.0` release (e.g. `10.0`) falls back to the GA `dist/` path instead
of `eus/`.

---

## How it works

1. Asserts the build host is RHEL 9/10.
2. Installs `image-builder` and `qemu-img`.
3. Templates a repo JSON and a blueprint TOML per target version.
4. Runs `image-builder build qcow2` for each version against the custom repo
   directory.
5. Copies each resulting qcow2 into the output directory.

The repo JSON points `image-builder` at the EUS CDN content so the build pulls
the correct minor-version packages. The blueprint's firstboot service then pins
the *running* system to EUS at first boot, since the build itself uses base
repos.

---

## RHEL 7

The `image-builder` CLI is osbuild-based and targets **RHEL 8+ only** — it
cannot produce a `rhel-7.x` image. RHEL 7 also reached end of Maintenance
Support in June 2024 (ELS only). Two options:

1. **Recommended:** Download the official **RHEL 7.9 KVM Guest Image** (qcow2)
   from [access.redhat.com](https://access.redhat.com) and import it straight
   into Proxmox. No build required.
2. If you need a *customized* RHEL 7 image, use the legacy
   `lorax-composer` / `composer-cli` on a RHEL 7 host. That's a separate
   workflow from this repo.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Assert fails on host version | You're not on RHEL 9/10. Move to a supported build host. |
| `image-builder` not found after install | Confirm the build host subscription includes the repo carrying `image-builder`. |
| Build times out | Increase the `async:` value in the build task. |
| Empty/unregistered image | `org_id` / `activation_key` not passed — firstboot service is skipped by design. |
| 404 pulling repo metadata | The targeted minor has no EUS repos. Use a real EUS minor or a `.0` GA release. |

---

## License

Provided as-is. Adapt freely for your environment.
