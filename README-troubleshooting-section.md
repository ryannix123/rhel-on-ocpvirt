## Networking: VMs must reach Satellite on the LAN

These VMs attach to the LAN via an OVN **localnet** so they pull DHCP leases
and DNS from your lab network — not the pod network. Two pieces make that work,
and they live in two different scopes:

- **Cluster-scoped** `NodeNetworkConfigurationPolicy` (NMState) maps the
  localnet name to `br-ex`. This survives namespace deletion.
- **Namespace-scoped** `NetworkAttachmentDefinition` (`manifests/00-nad.yaml`)
  connects VMs in the `rhel` namespace to that mapping. This does **not**
  survive `oc delete project` — which is exactly why it's committed here.

The NAD's JSON `name` and the NNCP `localnet:` value must match
(`vm-dhcp-network`), and `netAttachDefName` must be `<namespace>/<nad-name>`.

Apply everything together so the NAD lands before the VMs reference it:

```bash
oc apply -f manifests/          # 00-nad.yaml sorts first
```

## Troubleshooting registration

If a VM boots but never appears in Satellite, SSH in over the LAN and check
in this order:

```bash
ssh cloud-user@<vm-ip> \
  "sudo subscription-manager identity; \
   getent hosts satellite.example.com || echo DNS-FAIL; \
   curl -sk -o /dev/null -w 'HTTP:%{http_code}\n' https://satellite.example.com/register"
```

| Symptom | Cause | Fix |
|---|---|---|
| `identity` shows org + UUID | Already registered | Refresh Satellite → **Hosts > All Hosts** |
| HTTP 401 in cloud-init log | **Registration JWT expired** (4h default) | Regenerate with `--jwt-expiration`, recreate secrets, reapply |
| `DNS-FAIL` / `HTTP:000` | VM's DHCP-provided resolver doesn't know the Satellite FQDN | Add an A record to the **lab DNS your DHCP hands out** (not just your workstation). Interim: pin in the guest and rerun the registration script (below) |
| VM on `10.128.x` (pod) IP | NAD missing / not referenced | Ensure `00-nad.yaml` applied and VM specs use the `bridge` + `multus` interface |

### Interim DNS pin + re-register (no rebuild)

cloud-init's NoCloud runs once per instance, so a reboot won't re-register.
To fix a running VM in place:

```bash
SAT_IP=<satellite-ip>
for vm in <vm-ips>; do
  ssh cloud-user@$vm \
    "grep -q satellite.example.com /etc/hosts || \
       echo '$SAT_IP satellite.example.com' | sudo tee -a /etc/hosts >/dev/null; \
     sudo bash /var/lib/cloud/instance/scripts/* && sudo subscription-manager identity"
done
```

## Gotchas worth knowing

- **JWTs expire.** Registration tokens default to a 4-hour lifetime. Reusing an
  old one fails silently inside cloud-init. Generate a fresh token (and set
  `--jwt-expiration` to something sane) before each rebuild.
- **If it's not in Git, it doesn't exist.** The NAD used to live only in etcd;
  `oc delete project` erased it and nothing could rebuild it. It's committed now.
- **Guests resolve via DHCP's DNS, not yours.** Your workstation resolving the
  Satellite FQDN says nothing about whether the VMs can.
- **Lightspeed views need a real org context.** In the Satellite UI, the
  Recommendations / Vulnerability pages error out ("something went wrong") under
  *Any organization* or *Any location*. Scope into a specific organization first.
- **`cloud-user` is the login;** root's password is locked (SSH-key only). Use
  `virtctl ssh cloud-user@vmi/<name> -n rhel` when the LAN path is down.
