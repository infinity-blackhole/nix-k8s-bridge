# nix-k8s-bridge

PoC: bridge `pkgs.dockerTools.buildImage` into Kubernetes manifests with the
registry digest computed **at nix eval time** — no registry round-trip, no
manual repin, no container tooling.

## The claim, proven end-to-end

```bash
nix build .#oci-layout .#poc-image-digest
cat ./result-poc-image-digest
#   sha256:3f1c2ea8…            <- known BEFORE any push
./push.sh "$(readlink -f ./result-oci-layout)" bridge-poc poc http://localhost:5555
curl -s -H "Accept: application/vnd.oci.image.manifest.v1+json" -I \
  http://localhost:5555/v2/bridge-poc/manifests/poc | grep -i docker-content-digest
#   Docker-Content-Digest: sha256:3f1c2ea8…   <- IDENTICAL
```

`packages.#kustomize-pin` renders the kustomize `images:` transformer carrying
that digest. One flake eval owns image + pin; CI pushes byte-exact and commits
the pin — the manual repin loop is gone.

## How it works (no skopeo, sandbox-safe)

`oci-layout` derivation: extract the docker-archive tarball, content-address
config + layer blobs (`sha256sum`), assemble the OCI manifest + `index.json`
with `printf`. Pure nix output; deterministic because `dockerTools` pins
`created` to epoch+1.

`push.sh`: POST blob uploads + PUT the manifest **verbatim** via the registry
HTTP API.

## The three traps this design avoids

1. **docker-archive pushes recompress layers.** Observed: 61MB uncompressed
   layer → 5.3MB gzip, different digest. Hashing the archive manifest can
   never predict the registry digest.
2. **skopeo remarshals OCI manifests** (→ Docker schema2 media types) even
   when pushing layout→registry. Any tool-driven push changes the bytes.
3. **skopeo's docker-archive transport hardcodes `/var/tmp`** — cannot run in
   the Linux nix sandbox at all.

Byte-exactness requires owning both ends: assemble in nix, push with curl.

## Multi-arch ceiling

The layout pins one platform manifest. A mixed-arch fleet needs the **index**
digest (a platform digest pins every node to one arch — containerd does no
arch check on digest pulls). Extend by merging per-arch layouts into an OCI
index before hashing; `index.json` then names the index digest the same way.

## Repo layout

- `flake.nix` — image → layout → digest → kustomize pin, with self-checks
- `push.sh` — byte-exact registry push (the bridge's deploy half)
- `.github/workflows/nix.yaml` — `nix flake check` + pin render

Registry acceptance executed against an ephemeral `registry:2` pod: registry
digest == eval-time digest, byte-exact. Bootstrapped via sks-repo; 5-ruleset
template from infinity-blackhole/orbit.
