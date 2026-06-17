# SealedSecret examples

The four `*.sealedsecret.yaml.example` files in this directory are
**templates** — their `encryptedData` blocks contain placeholder strings
that will NOT decrypt against any real cluster.

To produce the working SealedSecret a cluster needs:
1. Install the **sealed-secrets** controller in the cluster
   (`platform/secrets/sealed-secrets.yaml` does this; lands at sync-wave -18).
2. Run the `kubeseal` commands documented in
   [platform/secrets/README.md](../../../platform/secrets/README.md).
3. Save the output as `<name>.sealedsecret.yaml` (drop the `.example`
   suffix). The `saga-credentials` ArgoCD app watches this directory with
   the glob `*.sealedsecret.yaml`, so the sealed file is picked up
   automatically; the `*.example` files end in `.yaml.example` and are
   skipped.

**Never commit a non-`.example` `SealedSecret` whose `encryptedData`
contains placeholder strings.** The sealed-secrets controller will refuse
to decrypt and the resulting Secret will never be created.
