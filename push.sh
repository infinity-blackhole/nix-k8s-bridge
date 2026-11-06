#!/usr/bin/env bash
# push.sh <layout-dir> <repo> <tag> [registry]
# Byte-exact push of a nix-built OCI layout: uploads blobs, then PUTs the
# manifest VERBATIM, so the registry digest equals the layout's eval-time
# digest. (skopeo/docker push remarshal manifests and change the digest —
# only the raw registry API preserves bytes.)
set -euo pipefail
layout=$1; repo=$2; tag=$3; reg=${4:-localhost:5555}

m=$(jq -r '.manifests[0].digest' "$layout/index.json")
mf="$layout/blobs/sha256/${m#sha256:}"

for b in $(jq -r '.layers[].digest, .config.digest' "$mf"); do
  f="$layout/blobs/sha256/${b#sha256:}"
  loc=$(curl -s -X POST -H "Content-Length: 0" -D - -o /dev/null \
    "$reg/v2/$repo/blobs/uploads/" | grep -i '^location:' | tr -d '\r' | cut -d' ' -f2)
  case $loc in http*) ;; *) loc="$reg$loc";; esac
  sep='?'; [[ $loc == *\?* ]] && sep='&'
  curl -sf -X PUT -H "Content-Type: application/octet-stream" \
    --data-binary @"$f" "$loc${sep}digest=$b" -o /dev/null
done

curl -sf -X PUT -H "Content-Type: application/vnd.oci.image.manifest.v1+json" \
  --data-binary @"$mf" "$reg/v2/$repo/manifests/$tag" -o /dev/null
echo "$reg/$repo:$tag@$m"
