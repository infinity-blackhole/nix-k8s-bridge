# nix-k8s-bridge

PoC: bridge `pkgs.dockerTools.buildImage` into Kubernetes manifests with the
registry digest computed **at nix eval time** — no registry round-trip, no
manual repin.

## The claim, proven

```bash
nix build .#poc-image-digest   # sha256:223c03e3…  (known before any push)
nix build .#oci-layout         # deterministic OCI layout
skopeo copy --dest-tls-verify=false \
  oci:$(nix build .#oci-layout --print-out-paths):bridge-poc \
  docker://<registry>/bridge-poc:poc
# registry answers: Docker-Content-Digest: sha256:223c03e3…  — identical
```

`packages.#kustomize-pin` renders the kustomize `images:` transformer carrying
that digest. One flake eval owns image + pin; a CI push + pin commit closes
the loop into a GitOps repo.

## The trap this design avoids

Hashing the `docker-archive` manifest does **not** predict the registry
digest: registry pushes recompress layers and rewrite the manifest (observed:
61MB uncompressed layer became a 5.3MB gzip blob, different digest). The
bridge normalizes once — `docker-archive → oci:` layout, content-addressed and
deterministic — reads the manifest digest from `index.json`, and pushes **from
that layout**, so the registry stores exactly the hashed bytes.

Determinism: `dockerTools` defaults `created` to epoch+1, and the conversion
is pure, so the same closure always yields the same digest.

## Multi-arch ceiling

`oci-layout` pins one platform manifest. A mixed-arch fleet needs the
**index** digest (a platform digest pins every node to one arch — containerd
does no arch check on digest pulls). Extend by merging per-arch layouts into
an OCI index before hashing; `index.json` then names the index digest the same
way.

## Repo layout

- `flake.nix` — everything: image, layout, digest, pin, checks
- `.github/workflows/nix.yaml` — `nix flake check` + pin render on PR/push

Registry acceptance was executed against an ephemeral `registry:2` pod pushed
from the layout; digests matched byte-for-byte.
