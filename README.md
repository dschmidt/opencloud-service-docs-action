# opencloud-service-docs-action

Composite GitHub Action that generates a documentation site for an
OpenCloud-compatible Go service. It introspects the service's config struct
via [opencloud-eu/markdown-docs-generator](https://github.com/opencloud-eu/markdown-docs-generator)
(Apache-2.0), renders the results through a [Docusaurus](https://docusaurus.io)
site templated after [opencloud-eu/docs](https://github.com/opencloud-eu/docs)
(AGPL-3.0), and hands back a path to the built site.

Runs identically in CI and locally (via `bash build.sh`) — the action is a
thin wrapper that sets up Go, Node, and pnpm before invoking the same shell
script.

> [!NOTE]
> This action currently lives under `dschmidt/` for incubation. Once proven
> with one or two real services, it's intended to be donated to the
> `opencloud-eu/` organization.

## Quick start

1. Add `opencloud-service.yml` to your service repo's root:

   ```yaml
   service:
     name: <your-service>            # e.g. synaplan
     go_mod_dir: backend             # or "." if go.mod is at the repo root

   site:
     title: <your-service>           # header / tab title
     tagline: Short description

   pins:
     generator_ref: <commit-hash>    # opencloud-eu/markdown-docs-generator
     theme_ref: <commit-hash>        # opencloud-eu/docs
   ```

2. Add a workflow at `.github/workflows/docs.yml`:

   ```yaml
   name: Docs
   on:
     push: { branches: [main] }
     pull_request:
   concurrency:
     group: docs-${{ github.ref }}
     cancel-in-progress: true
   jobs:
     build:
       runs-on: ubuntu-latest
       permissions: { contents: read }
       outputs:
         site-path: ${{ steps.build.outputs.site-path }}
       steps:
         - uses: actions/checkout@v4
         - id: build
           uses: dschmidt/opencloud-service-docs-action@<sha>
         # --- PR dry-run: downloadable site preview, never published -----
         # - name: Upload PR preview artifact
         #   if: github.event_name == 'pull_request'
         #   uses: actions/upload-artifact@v4
         #   with:
         #     name: site-preview
         #     path: ${{ steps.build.outputs.site-path }}
         #     retention-days: 14
         # --- Pages-bound artifact (main-only) ---------------------------
         # - name: Upload Pages artifact
         #   if: github.ref == 'refs/heads/main'
         #   uses: actions/upload-pages-artifact@v3
         #   with:
         #     path: ${{ steps.build.outputs.site-path }}

     # --- GitHub Pages deploy (uncomment after enabling Pages --------------
     # --- in repo settings: Settings → Pages → Build and deployment: ------
     # --- Source = GitHub Actions) ---------------------------------------
     # deploy:
     #   if: github.ref == 'refs/heads/main'
     #   needs: build
     #   runs-on: ubuntu-latest
     #   permissions: { pages: write, id-token: write }
     #   environment:
     #     name: github-pages
     #     url: ${{ steps.deploy.outputs.page_url }}
     #   steps:
     #     - id: deploy
     #       uses: actions/deploy-pages@v4
   ```

3. *(Optional)* For local preflight, drop a tiny bootstrap script into your
   repo and wire a Makefile target — see [Local development](#local-development)
   below. The bootstrap clones this action at the SHA pinned in your workflow
   and runs the exact same `build.sh` that CI runs.

## Inputs

| Input         | Required | Default                                  | Purpose                                             |
|---------------|:--------:|------------------------------------------|-----------------------------------------------------|
| `config-path` | no       | `opencloud-service.yml`                  | Repo-relative path to the service config.           |
| `output-path` | no       | `<repo>/.cache/service-docs/site-build`  | Where to place the built site. Absolute or relative. |

## Outputs

| Output      | Description                                                                 |
|-------------|-----------------------------------------------------------------------------|
| `site-path` | Absolute path to the built Docusaurus site (feed into `upload-pages-artifact`). |

## Config schema

Every field is optional unless marked **required**. Absent or `auto` fields
are filled in from the repo context.

```yaml
service:
  go_mod_dir: .                          # default: repo root
  module: auto                           # default: first `module` line in go.mod
  name: auto                             # default: last segment of module (overrides recommended)
  config_package: pkg/config             # default
  defaults_package: pkg/config/defaults  # default
  readme: README.md                      # default

site:
  title: <required>                      # actual text content — no sensible default
  tagline: ''                            # optional subtitle
  announcement: ''                       # optional site-wide banner (HTML allowed), see below
  docs_dir: docs                         # default; overlay dir for extra/overriding pages, see below
  organization: auto                     # default: $GITHUB_REPOSITORY_OWNER / git remote parse
  repository: auto                       # default: $GITHUB_REPOSITORY name / git remote parse
  url: auto                              # default: https://<org>.github.io
  base_url: auto                         # default: /<repo>/
  github_url: auto                       # default: <GITHUB_SERVER_URL>/<org>/<repo>

pins:
  generator_ref: <required>              # opencloud-eu/markdown-docs-generator commit
  theme_ref: <required>                  # opencloud-eu/docs commit
  # opencloud-eu/opencloud version is resolved automatically via
  # `go list -m` against the service's go.mod.
```

### About `service.name`

Used as the pseudo-service directory inside the cloned opencloud tree
(`tmp/services/<name>/`) and as the filename prefix for generator output
(e.g. `<name>_configvars.md`). It should match the `Name` field set in the
service's `config.Service{Name: "..."}`.

The autodetected default is the last segment of the module path, which often
differs from the runtime service name (e.g. module
`github.com/foo/synaplan-opencloud` maps to the service named `synaplan`).
**Set `service.name` explicitly** unless they happen to match.

### Announcement banner (`site.announcement`)

When set, the text renders as a non-closable banner at the top of **every**
page — the right place for status notices ("proof of concept", "requires
unreleased OpenCloud", "docs track `main`, not a release"). Inline HTML is
allowed; Docusaurus renders the content as HTML:

```yaml
site:
  announcement: >-
    🚧 Proof of concept — requires unreleased OpenCloud changes.
    <a href="https://github.com/you/your-service#readme">Details</a>
```

The banner is styled as a warning (amber, both color modes) via
`template/src/css/overlay.css`.

### Custom pages & overview override (`site.docs_dir`)

The template ships four pages: an overview (`intro.md`) plus the three
generated configuration pages. Anything the service repo puts under
`site.docs_dir` (default: the repo's `docs/` directory) is copied **over**
the template's `docs/` tree before the site builds — docs content lives in
the repo like any other source. Don't put non-page files (like the action
config) inside the overlay dir: everything there ends up in the published
site. The config belongs at the repo root, build scratch goes to
`.cache/service-docs/`, and `.github/` keeps only the workflow:

- A file at the same relative path **replaces** the template page —
  `docs/intro.md` replaces the default overview (keep its front matter:
  `slug: /` makes it the landing page).
- Any other `.md`/`.mdx` file becomes an **additional page**, picked up by
  the autogenerated sidebar. Use `sidebar_position` front matter to order
  pages, and `_category_.json` in subdirectories for section labels.
- The literal token `@@SERVICE@@` is substituted with `service.name` in
  overlay pages, same as in the template's own wrappers.

Because the default publishes the whole `docs/` tree, repos whose `docs/`
holds content *not* meant for the site (ADRs, internal notes) should point
`site.docs_dir` at a subdirectory (e.g. `docs/site`) or elsewhere. The
build refuses to run if the output path (`DOCS_OUTPUT`) lies inside the
overlay dir — otherwise a second run would re-publish the previously built
HTML as pages. Also don't put the overlay at `.cache/docs/`: that path is
swept after every build (an upstream generator template writes a stray
artifact there).

### `shared.Commons` handling

Services that embed `*shared.Commons` (tagged `yaml:"-"`) would otherwise
surface the full OpenCloud-wide env var inventory (`OC_ADMIN_USER_ID`,
`OC_MULTI_TENANT_ENABLED`, `REVA_TRANSFER_SECRET`, …) through reflection even
though the service doesn't intentionally expose them.

The generated shim zeroes a `Commons` field via reflection before the config
is walked, but only if that field exists. Services without a `Commons` field
need no configuration and compile fine, so there is no option to set.

**Known gap:** zeroing `Commons` also hides `OC_LOG_PRETTY` / `OC_LOG_COLOR` /
`OC_LOG_FILE`, which *are* consumed at runtime by `log.Configure`. Until
upstream grows a flag that respects `yaml:"-"` on pointers, the workaround
is to promote a `Log` section into your service's own `Config` struct.

## Pipeline (what `build.sh` does)

1. Parse `opencloud-service.yml` via `yq`, resolve defaults and autodetection.
2. Resolve the opencloud version via `go list -m` against the service's `go.mod`.
3. Clone `opencloud-eu/markdown-docs-generator` at `pins.generator_ref` into `<repo>/.cache/service-docs/generator/`.
4. `go mod download` opencloud at the resolved version; copy from GOMODCACHE into `<repo>/.cache/service-docs/generator/tmp/`.
5. Wipe every pre-existing `services/<x>/` directory under `tmp/`.
6. Render `shim/defaultconfig.go.tmpl` into `tmp/services/<service.name>/pkg/config/defaults/defaultconfig.go`. The shim delegates to the real `FullDefaultConfig()` via the module's import path (so reflection walks the real struct tags).
7. Copy the service README to `tmp/services/<service.name>/README.md`.
8. Patch the generator's `go.mod` with `require` + `replace` for the service module, bump the Go directive defensively, `go mod tidy`.
9. Run `go run ./cmd/dochelpers templates` and `service-index`.
10. Clone `opencloud-eu/docs` at `pins.theme_ref` into `<repo>/.cache/service-docs/theme/`.
11. Synthesize the site in `<repo>/.cache/service-docs/site/`:
    - Copy `template/` from the action.
    - Copy the service's docs overlay (`site.docs_dir`, if present) over `docs/`.
    - Render `docusaurus.config.ts.tmpl` via `envsubst` (including the optional announcement bar).
    - Substitute `@@SERVICE@@` placeholders in `.md`/`.mdx` pages via `sed`.
    - Copy theme CSS, strip `@font-face` / `.hero` blocks (branded assets we don't redistribute) and the `font-family: OpenCloud` token.
    - Drop generator outputs into `static/env-vars/`.
    - Write AGPL `LICENSE` + `ATTRIBUTION.md` into `static/`.
12. `pnpm install --prefer-frozen-lockfile && pnpm build`.
13. Copy `<site>/build/` → `$DOCS_OUTPUT` (default `.cache/service-docs/site-build/`; must not lie inside the docs overlay dir). The build stays in place at `.cache/service-docs/site/build/` so `pnpm run serve` in the cache dir just works.
14. Sweep the stray `docs/services/_includes/` directory the upstream generator template writes (it's hardcoded with a relative path that escapes its cwd).

## Local development

The action's `build.sh` runs standalone. In your service repo, drop a
bootstrap script that clones this action at the SHA pinned in your workflow
and invokes `build.sh`:

```bash
# dev/docs-run.sh
#!/usr/bin/env bash
set -euo pipefail
REF="$(grep -oE 'dschmidt/opencloud-service-docs-action@[^ "]+' \
         .github/workflows/docs.yml | head -1 | cut -d@ -f2)"
DIR=".cache/service-docs/action"
if [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" != "$REF" ]; then
  rm -rf "$DIR"
  git clone https://github.com/dschmidt/opencloud-service-docs-action.git "$DIR"
  git -C "$DIR" checkout "$REF"
fi
exec bash "$DIR/build.sh"
```

```makefile
# Makefile
docs:
	bash dev/docs-run.sh

docs-serve-prod:
	cd .cache/service-docs/site && pnpm run serve

docs-clean:
	rm -rf .cache/service-docs
```

Then `make docs` reproduces the CI build locally at the same pinned SHA.
The workflow file is the single source of truth for the action version —
no duplication in `opencloud-service.yml` or elsewhere.

## Caching

Within a single run's working tree, clones are reused across invocations:
if `.cache/service-docs/generator/`, `.cache/service-docs/theme/`, and the
opencloud unpack under `.cache/service-docs/generator/tmp/` are already at
the pinned refs/versions, they're not
re-fetched. The opencloud pin is tracked via a `.opencloud-version` marker
file (since `go mod download` unpacks a tarball, not a git tree).

## Required toolchain

The action installs everything itself via its composite steps. Running
locally requires the same tools on `PATH`:

- `yq` (mikefarah v4)
- `git`
- `go` ≥ 1.25 (matches or exceeds the service's `go.mod` directive)
- `pnpm` ≥ 10
- `node` ≥ 20
- `envsubst` (from GNU gettext, usually preinstalled)
- `awk`, `sed`, `find` (POSIX)

## Licensing

- This action, its shim, and its Docusaurus template are **Apache-2.0**.
- `opencloud-eu/markdown-docs-generator` and `opencloud-eu/opencloud` are
  **Apache-2.0** — no obligations bleed into your service.
- `opencloud-eu/docs`, whose CSS is copied into the synthesized site, is
  **AGPL-3.0**. The published site aggregates AGPL CSS and therefore is
  itself AGPL-3.0. `build.sh` drops an `AGPL-3.0` LICENSE plus an
  `ATTRIBUTION.md` into the site output; don't remove them from the deploy
  artifact.
- Opencloud-branded assets (fonts, banner images, logos) are **not** copied
  by the build — only palette/layout tokens. If you need custom branding,
  add overrides to `template/src/css/overlay.css` (layered after the theme's
  CSS) and ship your own assets under `static/img/`.

## Pin management

`pins.generator_ref` and `pins.theme_ref` should be full commit SHAs for
reproducibility. Unpinned (e.g. `main`) works but reruns become
non-deterministic as upstream advances.
