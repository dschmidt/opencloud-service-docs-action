#!/usr/bin/env bash
# Build a service docs site using opencloud-eu/markdown-docs-generator.
# Runs identically in CI (invoked by action.yml) and locally (via `make docs`).
set -euo pipefail

# ----- paths -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git -C "$(pwd)" rev-parse --show-toplevel)}"
CONFIG_PATH_INPUT="${DOCS_CONFIG:-.github/docs/opencloud-service.yml}"
# Make config path absolute relative to repo root unless already absolute.
case "$CONFIG_PATH_INPUT" in
  /*) CONFIG_PATH="$CONFIG_PATH_INPUT" ;;
  *)  CONFIG_PATH="$REPO_ROOT/$CONFIG_PATH_INPUT" ;;
esac
WORK_DIR="$REPO_ROOT/.github/docs/.cache"
DEFAULT_OUT="$WORK_DIR/site-build"
OUT_DIR="${DOCS_OUTPUT:-$DEFAULT_OUT}"
[ -n "$OUT_DIR" ] || OUT_DIR="$DEFAULT_OUT"

GEN_DIR="$WORK_DIR/generator"
OC_DIR="$GEN_DIR/tmp"
THEME_DIR="$WORK_DIR/theme"
SITE_DIR="$WORK_DIR/site"

# ----- required tools --------------------------------------------------------
for t in yq git go pnpm node envsubst awk sed; do
  command -v "$t" >/dev/null || { echo "error: required tool '$t' not found on PATH" >&2; exit 1; }
done

# ----- config parsing --------------------------------------------------------
# cfg_get <yq-path> <default>
cfg_get() {
  local v
  # A missing key yields "null"; real values (including boolean false) pass
  # through unchanged.
  v="$(yq -r "$1" "$CONFIG_PATH" 2>/dev/null)"
  if [ -z "$v" ] || [ "$v" = "null" ] || [ "$v" = "auto" ]; then
    printf '%s' "$2"
  else
    printf '%s' "$v"
  fi
}

GO_MOD_DIR="$(cfg_get '.service.go_mod_dir' '.')"
SERVICE_MODULE_IN="$(cfg_get '.service.module' '')"
SERVICE_NAME_IN="$(cfg_get '.service.name' '')"
CONFIG_PACKAGE="$(cfg_get '.service.config_package' 'pkg/config')"
DEFAULTS_PACKAGE="$(cfg_get '.service.defaults_package' 'pkg/config/defaults')"
README_PATH="$(cfg_get '.service.readme' 'README.md')"

SITE_TITLE="$(cfg_get '.site.title' '')"
[ -n "$SITE_TITLE" ] || { echo "error: site.title is required in $CONFIG_PATH" >&2; exit 1; }
SITE_TAGLINE="$(cfg_get '.site.tagline' '')"

GENERATOR_REF="$(cfg_get '.pins.generator_ref' '')"
[ -n "$GENERATOR_REF" ] || { echo "error: pins.generator_ref is required" >&2; exit 1; }
THEME_REF="$(cfg_get '.pins.theme_ref' '')"
[ -n "$THEME_REF" ] || { echo "error: pins.theme_ref is required" >&2; exit 1; }

# ----- autodetect module path & service name --------------------------------
if [ -n "$SERVICE_MODULE_IN" ]; then
  SERVICE_MODULE="$SERVICE_MODULE_IN"
else
  SERVICE_MODULE="$(awk '/^module /{print $2; exit}' "$REPO_ROOT/$GO_MOD_DIR/go.mod")"
fi
[ -n "$SERVICE_MODULE" ] || { echo "error: could not determine service module path" >&2; exit 1; }

if [ -n "$SERVICE_NAME_IN" ]; then
  SERVICE_NAME="$SERVICE_NAME_IN"
else
  SERVICE_NAME="${SERVICE_MODULE##*/}"
fi

# ----- autodetect org/repo/urls ---------------------------------------------
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  ORG_AUTO="${GITHUB_REPOSITORY%%/*}"
  REPO_AUTO="${GITHUB_REPOSITORY##*/}"
  SERVER_AUTO="${GITHUB_SERVER_URL:-https://github.com}"
else
  remote="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo '')"
  if [ -n "$remote" ]; then
    ORG_AUTO="$(printf '%s' "$remote" | sed -E 's|.*[:/]([^/:]+)/([^/]+)$|\1|' | sed 's/\.git$//')"
    REPO_AUTO="$(printf '%s' "$remote" | sed -E 's|.*[:/]([^/:]+)/([^/]+)$|\2|' | sed 's/\.git$//')"
  else
    ORG_AUTO=""
    REPO_AUTO="$SERVICE_NAME"
  fi
  SERVER_AUTO="https://github.com"
fi

SITE_ORG="$(cfg_get '.site.organization' "$ORG_AUTO")"
SITE_REPO="$(cfg_get '.site.repository' "$REPO_AUTO")"
SITE_URL="$(cfg_get '.site.url' "https://${SITE_ORG}.github.io")"
SITE_BASE_URL="$(cfg_get '.site.base_url' "/${SITE_REPO}/")"
SITE_GITHUB_URL="$(cfg_get '.site.github_url' "${SERVER_AUTO}/${SITE_ORG}/${SITE_REPO}")"

# ----- resolve opencloud version via Go tooling -----------------------------
# `go list -m` returns the resolved version string from the service's go.mod
# (respecting replace directives etc.), matching exactly what the service
# compiles against — no manual parsing or hash extraction needed.
OC_VERSION="$(cd "$REPO_ROOT/$GO_MOD_DIR" && go list -m -f '{{.Version}}' github.com/opencloud-eu/opencloud)"
[ -n "$OC_VERSION" ] || { echo "error: could not resolve github.com/opencloud-eu/opencloud from $GO_MOD_DIR/go.mod" >&2; exit 1; }

echo "==> service: $SERVICE_NAME ($SERVICE_MODULE)"
echo "    site:    $SITE_TITLE @ $SITE_URL$SITE_BASE_URL"
echo "    pins:    generator=$GENERATOR_REF theme=$THEME_REF opencloud=$OC_VERSION"

mkdir -p "$WORK_DIR"

# ----- step 1: clone generator ----------------------------------------------
if [ -d "$GEN_DIR/.git" ] && [ "$(git -C "$GEN_DIR" rev-parse HEAD 2>/dev/null)" = "$GENERATOR_REF" ]; then
  echo "==> generator clone present at $GENERATOR_REF, reusing"
else
  echo "==> cloning markdown-docs-generator @ $GENERATOR_REF"
  rm -rf "$GEN_DIR"
  git clone https://github.com/opencloud-eu/markdown-docs-generator.git "$GEN_DIR"
  git -C "$GEN_DIR" checkout "$GENERATOR_REF"
fi

# ----- step 2: fetch opencloud via Go module cache --------------------------
# Downloads opencloud at the resolved version (into GOMODCACHE, read-only)
# and copies the unpacked source to a writable location. Much faster than
# a git clone (tarball fetch vs full history) and avoids a second manual
# pin to keep in sync with go.mod.
OC_MARKER="$OC_DIR/.opencloud-version"
if [ -f "$OC_MARKER" ] && [ "$(cat "$OC_MARKER")" = "$OC_VERSION" ]; then
  echo "==> opencloud @ $OC_VERSION already unpacked, reusing"
else
  echo "==> go mod download github.com/opencloud-eu/opencloud@$OC_VERSION"
  OC_SRC="$(cd "$REPO_ROOT/$GO_MOD_DIR" && \
    go mod download -json "github.com/opencloud-eu/opencloud@$OC_VERSION" | \
    awk -F'"' '/"Dir":/{print $4; exit}')"
  [ -d "$OC_SRC" ] || { echo "error: opencloud source not found at '$OC_SRC'" >&2; exit 1; }
  rm -rf "$OC_DIR"
  mkdir -p "$(dirname "$OC_DIR")"
  cp -R "$OC_SRC" "$OC_DIR"
  chmod -R u+w "$OC_DIR"   # module cache is read-only; make writable
  printf '%s\n' "$OC_VERSION" > "$OC_MARKER"
fi

# ----- step 3: narrow services ----------------------------------------------
find "$OC_DIR/services" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +

# ----- step 4: render shim into pseudo-service ------------------------------
SYN_SVC="$OC_DIR/services/$SERVICE_NAME"
mkdir -p "$SYN_SVC/pkg/config/defaults"
export SERVICE_MODULE CONFIG_PACKAGE DEFAULTS_PACKAGE
envsubst '${SERVICE_MODULE} ${CONFIG_PACKAGE} ${DEFAULTS_PACKAGE}' \
  < "$SCRIPT_DIR/shim/defaultconfig.go.tmpl" \
  > "$SYN_SVC/pkg/config/defaults/defaultconfig.go"

# ----- step 5: service README for service-index ------------------------------
cp "$REPO_ROOT/$README_PATH" "$SYN_SVC/README.md"

# ----- step 6: patch generator go.mod and tidy ------------------------------
(
  cd "$GEN_DIR"
  go mod edit -dropreplace="$SERVICE_MODULE" 2>/dev/null || true
  go mod edit -droprequire="$SERVICE_MODULE" 2>/dev/null || true
  go mod edit -require="${SERVICE_MODULE}@v0.0.0-00010101000000-000000000000"
  go mod edit -replace="${SERVICE_MODULE}=$REPO_ROOT/$GO_MOD_DIR"
  # Bump Go directive defensively (upstream declares 1.24.6; synaplan is 1.25).
  go mod edit -go=1.25.0 -toolchain=go1.25.0
  go mod tidy
)

# ----- step 7: run the generator --------------------------------------------
export OC_BASE_DATA_PATH=/var/lib/opencloud
export OC_CONFIG_DIR=/etc/opencloud
(
  cd "$GEN_DIR"
  echo "==> go run ./cmd/dochelpers templates"
  go run ./cmd/dochelpers templates
  echo "==> go run ./cmd/dochelpers service-index"
  go run ./cmd/dochelpers service-index
)

# ----- step 8: clone theme --------------------------------------------------
if [ -d "$THEME_DIR/.git" ] && [ "$(git -C "$THEME_DIR" rev-parse HEAD 2>/dev/null)" = "$THEME_REF" ]; then
  echo "==> theme clone present at $THEME_REF, reusing"
else
  echo "==> cloning opencloud-eu/docs @ $THEME_REF"
  rm -rf "$THEME_DIR"
  git clone https://github.com/opencloud-eu/docs.git "$THEME_DIR"
  git -C "$THEME_DIR" checkout "$THEME_REF"
fi

# ----- step 9: synthesize site ----------------------------------------------
echo "==> synthesizing site in $SITE_DIR"
rm -rf "$SITE_DIR"
mkdir -p "$SITE_DIR"
cp -R "$SCRIPT_DIR/template/." "$SITE_DIR/"

# Render docusaurus.config.ts from template.
export SITE_TITLE SITE_TAGLINE SITE_ORG SITE_REPO SITE_URL SITE_BASE_URL SITE_GITHUB_URL
envsubst '${SITE_TITLE} ${SITE_TAGLINE} ${SITE_ORG} ${SITE_REPO} ${SITE_URL} ${SITE_BASE_URL} ${SITE_GITHUB_URL}' \
  < "$SITE_DIR/docusaurus.config.ts.tmpl" \
  > "$SITE_DIR/docusaurus.config.ts"
rm "$SITE_DIR/docusaurus.config.ts.tmpl"

# Substitute service name in MDX wrappers.
find "$SITE_DIR/docs" -name '*.mdx' -exec sed -i.bak "s/@@SERVICE@@/$SERVICE_NAME/g" {} +
find "$SITE_DIR/docs" -name '*.bak' -delete

# Copy theme CSS, then strip references to branded assets we don't (and
# shouldn't) ship: @font-face blocks point at opencloud-branded font files
# with unclear licensing beyond the repo's AGPL, and .hero uses an
# opencloud-branded banner image. Palette + layout tokens survive untouched.
mkdir -p "$SITE_DIR/src/css"
cp "$THEME_DIR/src/css/custom.css" "$SITE_DIR/src/css/theme.css"
# Strip @font-face blocks.
sed -i.bak '/^@font-face {/,/^}/d' "$SITE_DIR/src/css/theme.css"
# Strip .hero block (banner image).
sed -i.bak '/^\.hero {/,/^}/d' "$SITE_DIR/src/css/theme.css"
# Drop 'font-family: "OpenCloud"' so we fall back to the Infima default stack.
sed -i.bak '/--ifm-font-family-base:.*OpenCloud/d' "$SITE_DIR/src/css/theme.css"
rm -f "$SITE_DIR/src/css/theme.css.bak"

# Copy generator outputs into site's static/env-vars.
mkdir -p "$SITE_DIR/static/env-vars"
cp "$GEN_DIR/output/docs/${SERVICE_NAME}"*.md "$SITE_DIR/static/env-vars/" 2>/dev/null || true
cp "$GEN_DIR/output/docs/${SERVICE_NAME}.yaml" "$SITE_DIR/static/env-vars/" 2>/dev/null || true

# AGPL attribution file in site (theme source is AGPL-3.0).
if [ -f "$THEME_DIR/LICENSE" ]; then
  mkdir -p "$SITE_DIR/static"
  cp "$THEME_DIR/LICENSE" "$SITE_DIR/static/LICENSE"
fi
cat > "$SITE_DIR/static/ATTRIBUTION.md" <<EOF
# Attribution

This documentation site includes theme assets (CSS, fonts) derived from
[opencloud-eu/docs](https://github.com/opencloud-eu/docs) at commit
[\`${THEME_REF}\`](https://github.com/opencloud-eu/docs/tree/${THEME_REF}),
licensed under **AGPL-3.0-only**. The aggregate site is therefore AGPL-3.0-only.
See [LICENSE](./LICENSE) for the full text.

Env var tables and example YAML are produced by
[opencloud-eu/markdown-docs-generator](https://github.com/opencloud-eu/markdown-docs-generator)
at commit [\`${GENERATOR_REF}\`](https://github.com/opencloud-eu/markdown-docs-generator/tree/${GENERATOR_REF})
(Apache-2.0) from the ${SERVICE_NAME} service source at module path
\`${SERVICE_MODULE}\`.
EOF

# ----- step 10: install + build ---------------------------------------------
(
  cd "$SITE_DIR"
  echo "==> pnpm install"
  # dangerouslyAllowAllBuilds: pnpm 10+ otherwise fails the install with
  # ERR_PNPM_IGNORED_BUILDS for deps that ship postinstall scripts (e.g.
  # core-js). The theme deps are pinned, so allowing their build scripts here
  # is safe and keeps the install non-interactive.
  pnpm install --frozen-lockfile --config.dangerouslyAllowAllBuilds=true
  echo "==> pnpm build"
  pnpm build
)

# ----- step 11: publish build to OUT_DIR ------------------------------------
# Copy (not move) so `$SITE_DIR/build/` stays intact — lets `pnpm run serve`
# work from the Docusaurus project as its own hint suggests:
#   [INFO] Use `npm run serve` command to test your build locally.
rm -rf "$OUT_DIR"
mkdir -p "$(dirname "$OUT_DIR")"
cp -R "$SITE_DIR/build" "$OUT_DIR"

# ----- step 12: sweep stray generator artifact ------------------------------
# Upstream template writes to ../../docs/services/_includes/ which, under our
# cwd, escapes into .github/docs/docs/. Sweep away.
rm -rf "$REPO_ROOT/.github/docs/docs"

# ----- step 13: action output -----------------------------------------------
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "site-path=$OUT_DIR" >> "$GITHUB_OUTPUT"
fi

echo "==> Done. Built site: $OUT_DIR"
