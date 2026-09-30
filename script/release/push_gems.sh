#!/usr/bin/env bash
# Push built gems: platform gems first, the source gem last. Idempotent: a gem already on
# rubygems.org is accepted only if byte-identical (a rerun after a partial publish).
set -euo pipefail
dir="${1:?gem dir}"
version="${2:?version}"
api="${RUBYGEMS_API:-https://rubygems.org}"
# Exactly the release set, or nothing is pushed: 5 platform gems + the source gem.
expected=(x86_64-linux aarch64-linux x86_64-darwin arm64-darwin x64-mingw-ucrt)
for plat in "${expected[@]}"; do
  [ -f "$dir/honeymaker-$version-$plat.gem" ] || { echo "::error::missing honeymaker-$version-$plat.gem" >&2; exit 1; }
done
[ -f "$dir/honeymaker-$version.gem" ] || { echo "::error::missing honeymaker-$version.gem (source)" >&2; exit 1; }
count=$(find "$dir" -maxdepth 1 -name '*.gem' | wc -l | tr -d ' ')
[ "$count" = 6 ] || { echo "::error::expected 6 gems in $dir, found $count" >&2; exit 1; }
push() {
  local g="$1" ver plat sha remote
  if gem push "$g"; then return 0; fi
  ver=$(ruby -rrubygems/package -e 'print Gem::Package.new(ARGV[0]).spec.version' "$g")
  plat=$(ruby -rrubygems/package -e 'print Gem::Package.new(ARGV[0]).spec.platform' "$g")
  sha=$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$g")
  remote=$(curl -fsS "$api/api/v2/rubygems/honeymaker/versions/${ver}.json?platform=${plat}" \
           | ruby -rjson -e 'print JSON.parse($stdin.read)["sha"]')
  if [ "$sha" != "$remote" ]; then echo "::error::$g differs from the published gem" >&2; return 1; fi
  echo "$g already published with the same checksum"
}
for plat in "${expected[@]}"; do push "$dir/honeymaker-$version-$plat.gem"; done
push "$dir/honeymaker-$version.gem"
