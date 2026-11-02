#!/usr/bin/env bash
# Prepares and builds the images of the development stack from the sibling repositories (see compose.yaml):
# installs the API spec into the local Maven repository, packages the backend jar, generates the frontend's API
# client, then builds all images. Run it again after changes in any of the repositories.
set -Eeuo pipefail

dev_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$dev_dir/../.." && pwd)"

for repo in bike-maintainer-api bike-maintainer-backend bike-maintainer-frontend bike-maintainer-portal; do
    [ -d "$root/$repo" ] || { echo "Missing $root/$repo – check out all repositories side by side." >&2; exit 1; }
done

echo "== API spec"
(cd "$root/bike-maintainer-api" && mvn -q clean install)

echo "== Backend jar"
(cd "$root/bike-maintainer-backend" && ./mvnw -q clean package -DskipTests)

echo "== Frontend API client"
(cd "$root/bike-maintainer-frontend" && npm ci --no-audit --no-fund --silent && npm run -s generate:api)

echo "== Images"
cd "$dev_dir"
docker compose build
