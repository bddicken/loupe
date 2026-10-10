#!/bin/zsh
# Manually deploys web/ to Vercel production (loupe.pics).
#
# Normally you don't need this: the Vercel project is connected to the GitHub
# repo and deploys web/ whenever a push changes it (scripts/release.sh pushes).
# Use it to redeploy without a commit, e.g. if a Git deploy failed.
#
# Needs the Vercel CLI (`npm i -g vercel`) and `vercel login`. The project's
# Root Directory is web/, so this deploys from the repo root.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
PROJECT="${LOUPE_VERCEL_PROJECT:-loupe}"

[[ -f web/index.html ]] || { echo "No web/index.html. Run scripts/release.sh <version> first." >&2; exit 1; }
[[ -f .vercel/project.json ]] || vercel link --yes --project "$PROJECT"
vercel deploy --prod --yes
