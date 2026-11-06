{
  description = "PoC: nix-evaluated OCI digests bridging dockerTools images into kubernetes manifests";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          poc-image = pkgs.dockerTools.buildImage {
            name = "bridge-poc";
            tag = "poc";
            copyToRoot = pkgs.buildEnv {
              name = "bridge-poc-root";
              paths = [
                pkgs.hello
                pkgs.bash
              ];
              pathsToLink = [ "/bin" ];
            };
            config.Cmd = [ "${pkgs.hello}/bin/hello" ];
            # created = epoch+1 by default: deterministic, so the whole
            # image -> layout -> digest chain is a pure function of the closure.
          };

          # The bridge core, skopeo-free: assemble the OCI layout directly
          # from the docker-archive tarball (config + layer tars are all
          # there). Digest = sha256 of bytes nix itself produced — no
          # external tool, no registry round-trip, runs in the sandbox.
          # (skopeo's docker-archive transport hardcodes /var/tmp and
          # cannot run sandboxed on linux; also registry pushes of the
          # raw archive recompress layers and change the digest — observed
          # 61MB layer -> 5.3MB gzip. Push FROM this layout instead.)
          oci-layout = pkgs.runCommand "bridge-poc-oci"
            {
              nativeBuildInputs = [ pkgs.jq ];
            }
            ''
              set -eu
              mkdir -p $out/blobs/sha256 tmp
              tar -xf ${poc-image} -C tmp
              cfg=$(jq -r '.[0].Config' tmp/manifest.json)
              cfgd=''${cfg%.json}
              cp tmp/$cfg $out/blobs/sha256/$cfgd
              cfgsize=$(wc -c < $out/blobs/sha256/$cfgd | tr -d ' ')
              layers=""
              for l in $(jq -r '.[0].Layers[]' tmp/manifest.json); do
                d=$(sha256sum tmp/$l | cut -d' ' -f1)
                cp tmp/$l $out/blobs/sha256/$d
                sz=$(wc -c < tmp/$l | tr -d ' ')
                layers="$layers{\"mediaType\":\"application/vnd.oci.image.layer.v1.tar\",\"digest\":\"sha256:$d\",\"size\":$sz},"
              done
              printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%s},"layers":[%s]}' \
                "$cfgd" "$cfgsize" "''${layers%,}" > manifest.json
              md=$(sha256sum manifest.json | cut -d' ' -f1)
              cp manifest.json $out/blobs/sha256/$md
              msize=$(wc -c < manifest.json | tr -d ' ')
              printf '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:%s","size":%s,"annotations":{"org.opencontainers.image.ref.name":"bridge-poc"}}]}' \
                "$md" "$msize" > $out/index.json
              echo '{"imageLayoutVersion": "1.0.0"}' > $out/oci-layout
              # sanity: layout self-consistent (blob filename == content hash)
              echo "$md" | grep -qE '^[0-9a-f]{64}$' || { echo "bad manifest digest"; exit 1; }
              test "$(sha256sum $out/blobs/sha256/$md | cut -d' ' -f1)" = "$md" \
                || { echo "manifest blob content-address mismatch"; exit 1; }
            '';

          # digest read from the layout the push will use — no registry
          # round-trip, known before the push ever happens.
          poc-image-digest = pkgs.runCommand "bridge-poc-digest"
            {
              nativeBuildInputs = [ pkgs.jq ];
            }
            ''
              jq -r '.manifests[0].digest' ${oci-layout}/index.json | tr -d '\n' > $out
            '';

          # what a kustomization consumes: repo@digest, eval-time pinned
          kustomize-pin = pkgs.runCommand "kustomization-pin.yaml"
            {
              digest = builtins.readFile poc-image-digest;
            }
            ''
              printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nimages:\n  - name: bridge-poc\n    newName: registry.local:5000/bridge-poc\n    digest: %s\n' "$digest" > $out
            '';
        in
        {
          inherit
            poc-image
            oci-layout
            poc-image-digest
            kustomize-pin
            ;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (self.packages.${system}) poc-image-digest kustomize-pin;
        in
        {
          # digest shape is stable and the kustomization pin carries it verbatim
          digest-shape = pkgs.runCommand "digest-shape-check" { } ''
            grep -qE '^sha256:[0-9a-f]{64}$' ${poc-image-digest} \
              || { echo "digest not in sha256:<64hex> form"; exit 1; }
            grep -q "digest: $(cat ${poc-image-digest})" ${kustomize-pin} \
              || { echo "kustomize pin does not carry the digest"; exit 1; }
            touch $out
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell { packages = [ pkgs.skopeo ]; };
        }
      );
    };
}
