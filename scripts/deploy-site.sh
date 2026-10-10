#!/bin/zsh
# Deploys dist/site/ (made by scripts/release.sh) to Vercel production, served at loupe.pics.
#
# Usage: scripts/deploy-site.sh
#
# Needs the Vercel CLI (`npm i -g vercel`) and `vercel login`. The first run
# links dist/site/ to the "loupe" Vercel project; release.sh keeps that link.
set -euo pipefail

ROOT="${0:A:h:h}"
SITE="$ROOT/dist/site"
PROJECT="${LOUPE_VERCEL_PROJECT:-loupe}"

if [[ ! -f "$SITE/index.html" ]]; then
  echo "No $SITE/index.html. Run scripts/release.sh <version> first." >&2
  exit 1
fi

if [[ ! -f "$SITE/.vercel/project.json" ]]; then
  vercel link --yes --project "$PROJECT" --cwd "$SITE"
fi

vercel deploy --prod --yes --cwd "$SITE"
