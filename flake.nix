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

          # The bridge core: normalize ONCE into a content-addressed OCI
          # layout. Deterministic input => identical layout => identical
          # digests. Push happens FROM this layout, so the registry stores
          # exactly these bytes. (Hashing the docker-archive manifest instead
          # is a trap: registry pushes recompress layers and rewrite the
          # manifest — observed: 61MB uncompressed layer became a 5.3MB gzip
          # blob with a different digest.)
          oci-layout = pkgs.runCommand "bridge-poc-oci"
            {
              nativeBuildInputs = [
                pkgs.skopeo
                pkgs.jq
              ];
            }
            ''
              export REGISTRY_AUTH_FILE=$PWD/.skopeo-auth
              # sandbox has no containers policy.json; give skopeo an accept-all one
              echo '{"default":[{"type":"insecureAcceptAnything"}]}' > policy.json
              skopeo --policy policy.json copy docker-archive:${poc-image} oci:$out:bridge-poc
              # sanity: layout must be self-consistent (blob filename == content hash)
              m=$(jq -r '.manifests[0].digest' $out/index.json | cut -d: -f2)
              echo "$m" | grep -qE '^[0-9a-f]{64}$' || { echo "bad manifest digest in index.json"; exit 1; }
              test "$(sha256sum $out/blobs/sha256/$m | cut -d' ' -f1)" = "$m" \
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
