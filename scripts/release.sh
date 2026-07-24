#!/bin/bash
# Cut a release. Two phases, because main is PR-only:
#
#   scripts/release.sh prepare 0.2.0   # branch + bump Config/Version.xcconfig + open the release PR
#   scripts/release.sh tag             # after the PR merges: tag origin/main as vX.Y.Z + push the tag
#
# The version lives ONLY in Config/Version.xcconfig; `tag` reads it back from merged main, so the tag
# and MARKETING_VERSION physically cannot disagree (and CI re-checks on tag push as a second lock).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
XCCONFIG=Config/Version.xcconfig

case "${1:-}" in
prepare)
  VERSION="${2:?usage: release.sh prepare X.Y.Z}"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z" >&2; exit 1; }
  git fetch origin main
  # Build number = commit count of the release commit itself (origin/main + this bump, squashed to one).
  BUILD=$(( $(git rev-list --count origin/main) + 1 ))
  BRANCH="release/v${VERSION}"
  git switch -c "$BRANCH" origin/main
  # perl -pi, not sed -i: BSD and GNU sed disagree on the in-place flag's syntax.
  perl -pi -e "s/^MARKETING_VERSION = .*/MARKETING_VERSION = ${VERSION}/;
               s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = ${BUILD}/" "$XCCONFIG"
  git add "$XCCONFIG"
  git commit -m "chore(release): v${VERSION} (build ${BUILD})"
  git push -u origin "$BRANCH"
  gh pr create --fill --title "chore(release): v${VERSION}" \
    --body "Version bump only. After the checks pass, rebase-merge, then run \`scripts/release.sh tag\`."
  echo "PR opened. Once merged: scripts/release.sh tag"
  ;;
tag)
  git fetch origin main --tags
  VERSION=$(sed -n 's/^MARKETING_VERSION = //p' <(git show origin/main:"$XCCONFIG"))
  TAG="v${VERSION}"
  git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && { echo "${TAG} already exists" >&2; exit 1; }
  git tag -a "$TAG" -m "Parallax ${VERSION}" origin/main
  git push origin "$TAG"
  echo "Tagged origin/main as ${TAG}"
  ;;
*)
  echo "usage: release.sh prepare X.Y.Z | release.sh tag" >&2
  exit 1
  ;;
esac
