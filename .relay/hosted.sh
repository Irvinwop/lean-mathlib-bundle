#!/bin/bash
# Installed only on the carrier branch. Public stdout contains no private details.
set -euo pipefail
umask 077
mode=${1:?mode}
case "$mode" in prepare|shard|publish) ;; *) exit 2;; esac
mkdir -p .relay/out .relay/work
exec >.relay/work/driver.log 2>&1
export DEBIAN_FRONTEND=noninteractive
sudo apt-get -qq update
sudo apt-get -qq install -y age zstd cmake ninja-build
nonce=$(cat .relay/request.id)
[[ "$nonce" =~ ^[0-9a-f]{32}$ ]] || exit 2
pack() { tar --zstd -cf "$2" -C "$1" .; }
encrypt() { age -r "$BUNDLE_RESULT_RECIPIENT" -o "$2" "$1"; }
receipt() {
  local rc=$? kind=$1
  trap - EXIT
  set +e
  if [[ "$kind" == preparation ]]; then
    summary=.relay/work/payload/SUMMARY.json
  else
    summary=.relay/work/result/SUMMARY.json
  fi
  if [[ ! -s "$summary" ]]; then
    summary=.relay/work/FAILURE.json
    jq -n --arg nonce "$nonce" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" --arg kind "$kind" --argjson code "$rc" '{schema:"BUNDLE_INFRA_FAILURE1",complete:false,nonce:$nonce,run_id:$run,run_attempt:$attempt,phase:$kind,exit_code:$code}' > "$summary"
  fi
  encrypt "$summary" ".relay/out/$kind.summary.json.age"
  # Exclude credentials/runtime copies; preserve actual private diagnostics only.
  rm -f .relay/work/*.key
  mkdir -p .relay/evidence
  cp .relay/work/driver.log .relay/evidence/driver.log
  cp "$summary" .relay/evidence/SUMMARY.json
  if [[ "$kind" != preparation && -d .relay/work/result ]]; then cp -a .relay/work/result .relay/evidence/result; fi
  if [[ "$kind" == preparation && -d .relay/work/payload ]]; then cp -a .relay/work/payload .relay/evidence/build; fi
  pack .relay/evidence ".relay/out/$kind.evidence.tar.zst"
  encrypt ".relay/out/$kind.evidence.tar.zst" ".relay/out/$kind.evidence.tar.zst.age"
  rm -f ".relay/out/$kind.evidence.tar.zst"
  exit "$rc"
}
if [[ "$mode" == prepare ]]; then
  [[ "$BUNDLE_RUNTIME_SHA256" =~ ^[0-9a-f]{64}$ && "$BUNDLE_RUNTIME_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]]
  [[ "$BUNDLE_SOURCE_URL" =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]]
  printf '%s\n' "$BUNDLE_INPUT_IDENTITY" > .relay/work/input.key
  printf '%s\n' "$BUNDLE_SOURCE_KEY" > .relay/work/source.key
  printf '%s\n' "$BUNDLE_GITHUB_KNOWN_HOSTS" > .relay/work/known_hosts
  chmod 600 .relay/work/*.key
  trap 'receipt preparation' EXIT
  age -d -i .relay/work/input.key -o .relay/work/request.json .relay/request.age
  jq -e --arg nonce "$nonce" '(.nonce == $nonce) and (.source_sha|test("^[0-9a-f]{40}$")) and (.bot|test("^[A-Za-z0-9][A-Za-z0-9_/-]{0,127}$")) and (.bot|contains("..")|not) and (.suite == "full640" or .suite == "conformance2") and .shards == 8' .relay/work/request.json >/dev/null
  source_sha=$(jq -r .source_sha .relay/work/request.json)
  export GIT_SSH_COMMAND="ssh -i $PWD/.relay/work/source.key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$PWD/.relay/work/known_hosts"
  git -c core.hooksPath=/dev/null clone --no-checkout "$BUNDLE_SOURCE_URL" .relay/work/source
  git -C .relay/work/source -c core.hooksPath=/dev/null checkout --detach "$source_sha"
  [[ "$(git -C .relay/work/source rev-parse HEAD)" == "$source_sha" ]]
  [[ -z "$(git -C .relay/work/source status --porcelain)" ]]
  [[ "$BUNDLE_RUNTIME_URL" == https://github.com/Irvinwop/lean-mathlib-bundle/releases/download/* ]]
  curl --fail --location --proto '=https' --tlsv1.2 --retry 2 --max-time 600 "$BUNDLE_RUNTIME_URL" -o .relay/work/runtime.age
  printf '%s  %s\n' "$BUNDLE_RUNTIME_SHA256" .relay/work/runtime.age | sha256sum -c -
  age -d -i .relay/work/input.key -o .relay/work/runtime.tar.zst .relay/work/runtime.age
  mkdir .relay/work/runtime
  tar --zstd --no-same-owner --no-same-permissions --strip-components=1 -xf .relay/work/runtime.tar.zst -C .relay/work/runtime
  printf '%s  %s\n' "$BUNDLE_RUNTIME_MANIFEST_SHA256" .relay/work/runtime/manifest.json | sha256sum -c -
  node .relay/work/source/.ci/arena/arena.cjs validate-runtime --runtime .relay/work/runtime
  node .relay/work/source/.ci/arena/arena.cjs prepare --runtime .relay/work/runtime --checkout .relay/work/source --request .relay/work/request.json --out .relay/work/payload
  mkdir .relay/work/input
  mv .relay/work/runtime .relay/work/input/runtime
  mv .relay/work/payload .relay/work/input/payload
  cp -a .relay/work/source/.ci/arena .relay/work/input/arena
  # Keys and the source checkout are deliberately excluded from the worker payload.
  pack .relay/work/input .relay/work/input.tar.zst
  age -r "$BUNDLE_INPUT_RECIPIENT" -o .relay/out/input.age .relay/work/input.tar.zst
  mkdir .relay/work/payload
  cp .relay/work/input/payload/SUMMARY.json .relay/work/payload/SUMMARY.json
  rm -f .relay/work/*.key
elif [[ "$mode" == shard ]]; then
  [[ "$BUNDLE_SHARD" =~ ^[0-7]$ ]]
  printf '%s\n' "$BUNDLE_INPUT_IDENTITY" > .relay/work/input.key
  trap 'receipt check-'"$BUNDLE_SHARD" EXIT
  age -d -i .relay/work/input.key -o .relay/work/input.tar.zst .relay/download/input.age
  mkdir .relay/work/input
  tar --zstd --no-same-owner --no-same-permissions -xf .relay/work/input.tar.zst -C .relay/work/input
  rm -f .relay/work/input.key .relay/work/input.tar.zst
  node .relay/work/input/arena/arena.cjs shard --runtime .relay/work/input/runtime --payload .relay/work/input/payload --shard "$BUNDLE_SHARD" --shards 8 --out .relay/work/result
else
  # Only ciphertext and a public identity/hash inventory are published.
  [[ "$GITHUB_REPOSITORY" == Irvinwop/lean-mathlib-bundle ]]
  find .relay/releases -type f ! -name '*.age' -delete
  rm -f .relay/releases/input.age
  [[ -s .relay/releases/preparation.summary.json.age ]]
  assets=.relay/work/assets.ndjson
  : > "$assets"
  for file in .relay/releases/*.age; do
    [[ -f "$file" ]] || continue
    name=${file##*/}
    [[ "$name" =~ ^(preparation|check-[0-7])\.(summary\.json|evidence\.tar\.zst)\.age$ ]] || exit 2
    sha=$(sha256sum "$file" | cut -d' ' -f1)
    bytes=$(stat -c %s "$file")
    jq -n --arg name "$name" --arg sha "$sha" --argjson bytes "$bytes" '{name:$name,sha256:$sha,bytes:$bytes}' >> "$assets"
  done
  jq -s --arg nonce "$nonce" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" --arg commit "$GITHUB_SHA" '{schema:"BUNDLE_READY1",nonce:$nonce,run_id:$run,run_attempt:$attempt,carrier_commit:$commit,assets:.}' "$assets" > .relay/work/READY.json
  tag=bundle-check-$nonce
  gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" --title 'Bundle receipt' --notes 'Encrypted validation artifacts.'
  gh release upload "$tag" .relay/releases/*.age --repo "$GITHUB_REPOSITORY"
  # READY is the commit marker, uploaded only after every ciphertext is present.
  gh release upload "$tag" .relay/work/READY.json --repo "$GITHUB_REPOSITORY"
fi
