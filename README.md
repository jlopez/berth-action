# `berth-action`

Reusable composite actions for deploying a vessel's **full Docker Compose stack**
to an ephemeral per-PR preview URL (and a fixed `main` URL) via the self-hosted
[**berth**](https://webhook.jesusla.com/hooks/berth) runner — a personal OCI host
that checks out the vessel at a ref, materializes its `deploy/compose.yml`, writes
per-deploy secrets, and runs `docker compose up`/`down` behind a Caddy
`*.jesusla.com` wildcard.

A **vessel** is any allowlisted repo. It announces a deploy by POSTing one
HMAC-SHA256-signed JSON body to the runner. These three actions are the duplicated
CI boilerplate of that handshake, lifted out of the vessels verbatim so a new
vessel is a few lines of YAML plus a `deploy/compose.yml`.

## The three actions

| action          | what it does                                                              | needs secrets? | network |
| --------------- | ------------------------------------------------------------------------- | -------------- | ------- |
| `berth-plan`    | Compute the deploy plan (instance/host-base/tag/ref/branch/up-down-skip) from the event. | no  | no      |
| `berth-notify`  | Assemble + HMAC-sign + POST the contract body, then wait until the stack docks. | yes (HMAC key) | yes     |
| `berth-comment` | Upsert a single PR comment listing the preview URLs.                      | no (PR token)  | yes     |

They compose: `berth-plan` runs in a cheap `meta` job and feeds its outputs to the
vessel's own `build` job and to `berth-notify` + `berth-comment` in a `berth` job.
`berth-plan` is pure (no secret, no network), so it can't read `secrets` — instead
of emitting a `has_berth` flag, `berth-notify` simply no-ops when its
`webhook-secret` is empty. That keeps a vessel green before berth is configured and
leaves room for a future secret-less GitHub-OIDC mode.

## The compose contract (vessel side)

A vessel ships a `deploy/compose.yml` that **is** its deployed topology and travels
with the ref (the PR branch for previews, `main` for production). The runner
injects exactly two variables and writes one file — the same compose then produces
every environment:

- **`TAG`** — image tag to run: `main` (prod) or `pr-<n>` (preview).
- **`HOST_BASE`** — Caddy hostname base, **no trailing dash**: `gubs` (prod) or
  `gubs-pr-<n>`. Routing is the vessel's call:
  - a **root** service uses the base alone → `caddy: ${HOST_BASE}.jesusla.com`
    (so `gubs.jesusla.com` / `gubs-pr-8.jesusla.com`);
  - a **suffixed** service joins the base with a dash →
    `caddy: ${HOST_BASE}-sim.jesusla.com` (so `gubs-sim.jesusla.com` /
    `gubs-pr-8-sim.jesusla.com`).
- an **`env` file** written next to the compose from the `secrets` payload (always
  written, even empty; `0600`, removed on teardown).

The stack joins the **external `proxy` network**; Caddy reads each service's
`caddy:` labels and issues the cert via the wildcard. Use long-form `env_file` so a
key-free run (no `env`) still works:

```yaml
services:
  web:                                          # the root service
    image: ghcr.io/jlopez/gubs-web:${TAG:-main}
    pull_policy: always
    env_file:
      - path: env
        required: false   # absent for key-free runs
    networks: [proxy]
    labels:
      caddy: ${HOST_BASE:-gubs}.jesusla.com     # → gubs.jesusla.com / gubs-pr-8.jesusla.com
      caddy.reverse_proxy: '{{upstreams 3000}}'
    restart: unless-stopped
  sim-viewer:                                   # a suffixed service
    image: ghcr.io/jlopez/gubs-sim-viewer:${TAG:-main}
    pull_policy: always
    env_file:
      - path: env
        required: false
    networks: [proxy]
    labels:
      caddy: ${HOST_BASE:-gubs}-sim.jesusla.com  # → gubs-sim... / gubs-pr-8-sim...
      caddy.reverse_proxy: '{{upstreams 4173}}'
    restart: unless-stopped

networks:
  proxy:
    external: true
```

## Complete vessel `deploy.yml`

The `meta` and `berth` jobs are fully generic (these actions). The `build` job is
**vessel-specific** and shown only as a placeholder — it is *not* part of this
action; swap in your own Dockerfile, image names, build-args, and matrix.

```yaml
name: Deploy
on:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize, reopened, closed]

permissions:
  contents: read
  packages: write          # build job pushes images to ghcr
  pull-requests: write      # berth-comment upserts the preview comment

concurrency:
  group: deploy-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  meta:
    runs-on: ubuntu-latest
    outputs:
      deploy: ${{ steps.plan.outputs.deploy }}
      action: ${{ steps.plan.outputs.action }}
      instance: ${{ steps.plan.outputs.instance }}
      host-base: ${{ steps.plan.outputs.host-base }}
      tag: ${{ steps.plan.outputs.tag }}
      ref: ${{ steps.plan.outputs.ref }}
      branch: ${{ steps.plan.outputs.branch }}
      services: ${{ steps.svc.outputs.services }}
    steps:
      - id: plan
        uses: jlopez/berth-action/berth-plan@v1
        with:
          slug: gubs
      # Single source of truth for the UI services — drives the build matrix AND
      # the berth-comment URLs. `host` must match each service's Caddy host suffix;
      # an empty/absent `host` marks the root service (→ ${HOST_BASE}.jesusla.com).
      - id: svc
        run: |
          echo 'services=[{"name":"web","host":"","entry":"packages/web/src/server.ts","port":"3000"},{"name":"sim-viewer","host":"sim","entry":"packages/sim-viewer/src/server.ts","port":"4173"}]' >> "$GITHUB_OUTPUT"

  # ─── vessel-specific; example only, NOT part of berth-action ───────────────
  build:
    needs: meta
    if: needs.meta.outputs.deploy == 'true' && needs.meta.outputs.action == 'up'
    runs-on: ubuntu-24.04-arm   # native arm64 — the berth host is aarch64
    strategy:
      matrix:
        service: ${{ fromJSON(needs.meta.outputs.services) }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ github.token }}
      - uses: docker/build-push-action@v6
        with:
          context: .
          file: deploy/Dockerfile
          platforms: linux/arm64
          push: true
          tags: ghcr.io/jlopez/gubs-${{ matrix.service.name }}:${{ needs.meta.outputs.tag }}
          build-args: |
            ENTRY=${{ matrix.service.entry }}
            PORT=${{ matrix.service.port }}
  # ───────────────────────────────────────────────────────────────────────────

  berth:
    needs: [meta, build]
    # Run after a successful build (up), or directly for teardown (down).
    if: >
      always() && needs.meta.outputs.deploy == 'true' &&
      ( needs.meta.outputs.action == 'down' || needs.build.result == 'success' )
    runs-on: ubuntu-latest
    steps:
      - uses: jlopez/berth-action/berth-notify@v1
        with:
          webhook-secret: ${{ secrets.BERTH_WEBHOOK_SECRET }}
          ref: ${{ needs.meta.outputs.ref }}
          instance: ${{ needs.meta.outputs.instance }}
          host-base: ${{ needs.meta.outputs.host-base }}
          tag: ${{ needs.meta.outputs.tag }}
          action: ${{ needs.meta.outputs.action }}
          # Forwarded to the stack host-side (written into the compose `env`
          # file). Unset secrets resolve to empty and are dropped automatically.
          secrets: |
            OPENAI_API_KEY=${{ secrets.OPENAI_API_KEY }}
            GUBS_REPORT_GITHUB_TOKEN=${{ secrets.GUBS_REPORT_GITHUB_TOKEN }}

      - if: github.event_name == 'pull_request'
        uses: jlopez/berth-action/berth-comment@v1
        with:
          services: ${{ needs.meta.outputs.services }}
          host-base: ${{ needs.meta.outputs.host-base }}
          action: ${{ needs.meta.outputs.action }}
```

## Inputs / outputs

### `berth-plan`

| input  | required | meaning                                                   |
| ------ | -------- | --------------------------------------------------------- |
| `slug` | yes      | Short vessel name used to build `host-base` (e.g. `gubs`). |

| output        | meaning                                                       |
| ------------- | ------------------------------------------------------------- |
| `deploy`      | `'true'` when there's something to deploy; `'false'` on forks. |
| `action`      | `up` \| `down` \| `skip`.                                     |
| `instance`    | `pr-<n>` or `main`; empty on forks.                           |
| `host-base`   | Caddy hostname base, no trailing dash, e.g. `gubs-pr-8` / `gubs`. |
| `tag`         | Image tag: `pr-<n>` or `main`.                                |
| `ref`         | Commit SHA to deploy (PR head SHA, or `github.sha` on main).  |
| `branch`      | PR head branch; empty on main and forks.                     |

### `berth-notify`

| input            | required | default                                  | meaning                                              |
| ---------------- | -------- | ---------------------------------------- | ---------------------------------------------------- |
| `webhook-secret` | no       | `''`                                     | HMAC key; empty → no-op + notice.                    |
| `webhook-url`    | no       | `https://webhook.jesusla.com/hooks/berth` | Runner endpoint.                                     |
| `repo`           | no       | `${{ github.repository }}`               | `owner/name` of the vessel.                          |
| `ref`            | yes      | —                                        | Commit SHA to deploy.                                |
| `instance`       | yes      | —                                        | `pr-<n>` or `main`.                                  |
| `host-base`      | yes      | —                                        | Caddy hostname base, no trailing dash.              |
| `tag`            | yes      | —                                        | Image tag the build pushed.                          |
| `action`         | yes      | —                                        | `up` or `down`.                                      |
| `secrets`        | no       | `''`                                     | Multiline `KEY=value`; empty-value lines are dropped, split on the first `=`. |
| `wait`           | no       | `'true'`                                 | Poll the runner and fail the step unless the stack docks. `'false'` = fire-and-forget. |
| `wait-timeout`   | no       | `'900'`                                  | Overall budget (s), incl. time queued behind other deploys on the single-flock host. |
| `wait-running-timeout` | no | `'120'`                                | Backstop (s) once `running` — for a host that dies mid-deploy; the host fails unhealthy stacks itself in ~60s. |
| `poll-interval`  | no       | `'5'`                                    | Seconds between status polls.                        |
| `status-url`     | no       | `''` (derived from `webhook-url`)        | Status-readback endpoint; default swaps trailing `/berth` → `/berth-status`. |

| output      | meaning                                                                 |
| ----------- | ----------------------------------------------------------------------- |
| `deploy-id` | The `run_id-run_attempt` token sent as `deploy_id` and polled on; empty when the action no-ops. |

**Waiting (default).** `berth-notify` sends the payload, then polls
`/hooks/berth-status` until the runner reports `success` (step passes) or
`failure`/timeout (step fails) — so CI goes green only on a real deploy. "Docked"
means `docker compose up --wait` succeeded: a service with a `healthcheck` must
become healthy; one without counts as up once running. Set `wait: false` for the
old fire-and-forget behaviour.

> Waiting needs a runner that serves **`/hooks/berth-status`** (shipped alongside
> this feature). The `deploy_id` field is harmlessly ignored by an older runner,
> but the *poll* would never resolve against one — so update the host first, or
> use `wait: false` until it's deployed. (Back-compat applies to the contract
> **body**; the wait loop is a coordinated host+action change.)

### `berth-comment`

| input          | required | default                                          | meaning                                       |
| -------------- | -------- | ------------------------------------------------ | --------------------------------------------- |
| `services`     | yes      | —                                                | JSON array of `{name, host, …}` objects; empty/absent `host` = root service. |
| `host-base`    | yes      | —                                                | Caddy hostname base, no trailing dash.        |
| `action`       | yes      | —                                                | `up` (table) or `down` (torn-down note).      |
| `pr`           | no       | `${{ github.event.pull_request.number }}`        | PR number to comment on.                      |
| `head-sha`     | no       | `${{ github.event.pull_request.head.sha }}`      | Shown in the comment footer.                  |
| `github-token` | no       | `${{ github.token }}`                            | Needs `pull-requests: write`.                 |
| `repo`         | no       | `${{ github.repository }}`                        | `owner/name` whose PR is commented on.        |

## Auth

Set **`BERTH_WEBHOOK_SECRET`** as an Actions secret on the vessel; it's the shared
key the runner verifies the `X-Hub-Signature-256: sha256=<hex>` HMAC against, taken
over the **exact bytes** of the POSTed body (including `secrets`). The contract body
is:

```jsonc
{ "v": 1, "repo": "owner/name", "ref": "<sha>", "instance": "pr-8" | "main",
  "host_base": "gubs-pr-8" | "gubs", "tag": "pr-8" | "main",
  "action": "up" | "down", "deploy_id": "<run_id-run_attempt>",
  "secrets": { "KEY": "value", … } }
```

> `deploy_id` is a per-run correlation token the runner keys its deploy-status
> file on, so `berth-notify` can poll `/hooks/berth-status` until the stack docks.
> It's additive and backward-compatible (optional in the schema, ignored by an
> older runner), so it does **not** bump `v`.

> `v` is the **contract version**, fixed by `berth-notify` (not a caller input) and
> bumped only on a breaking body change, so the runner can branch on it. Unknown to
> an older runner, it's simply ignored — adding it is backward-compatible.
>
> JSON field names are **snake_case** (`host_base`) per the contract; action
> inputs/outputs use **kebab-case** (`host-base`) per Actions convention.

A secret-less, **zero-config GitHub-OIDC** mode is planned: the runner would verify
a short-lived OIDC token instead of a shared HMAC key. The `webhook-secret`-optional
interface above is forward-compatible with it — a vessel that omits the secret today
gets a clean no-op, and will get OIDC tomorrow without a YAML change.

## Contract schema

This repo is the **single source of truth** for the payload shape, so the wire
format and any host-side validator can't silently drift:

- [`berth-notify/body.jq`](./berth-notify/body.jq) is the one place the body is
  assembled — `berth-notify` builds the POST from it. Nothing else hand-writes the
  field set.
- [`schema/berth-payload.v1.json`](./schema/berth-payload.v1.json) is a JSON Schema
  for that body; [`examples/`](./examples) holds canonical `up`/`down` payloads.
- [CI](.github/workflows/ci.yml) locks all three together: it validates the
  examples against the schema **and** rebuilds them through `body.jq`, asserting the
  action's real output both matches the examples and validates. Rename a field or
  edit the shape and CI fails until schema, filter, and examples agree again.

**Host-side (private runner):** vendor the schema — copy `berth-payload.v1.json` in
with a header like `# synced from jlopez/berth-action@v1` — and **validate every
inbound payload against it before acting** (before the allowlist check), so a
malformed body is rejected ahead of any `docker compose`. The schema is public
(`raw.githubusercontent.com/jlopez/berth-action/v1/…`), so a private consumer can
fetch or pin it with no auth; vendoring keeps the deploy path free of a network
dependency and makes each contract bump an explicit, reviewed sync. The top level is
`additionalProperties: true` on purpose — that's what makes the `v`-gated forward
compatibility real, so don't tighten it to reject unknown future fields.

## Allowlist

The runner only deploys repos matching its `berth_repo_allowlist` (fnmatch over
`owner/name`, e.g. `jlopez/*`); everything else is rejected before any checkout.
Deploying arbitrary compose is effectively RCE gated by the HMAC secret, so a new
vessel must be added to the allowlist host-side first.

## Versioning

Pin **`@v1`** for the floating major (it tracks the latest `1.x`), or
`@vMAJOR.MINOR` / an exact `@vX.Y.Z` for a stricter pin:

```text
jlopez/berth-action/berth-plan@v1
jlopez/berth-action/berth-notify@v1
jlopez/berth-action/berth-comment@v1
```

This repo dogfoods [`jlopez/derive-version`](https://github.com/jlopez/derive-version)
in [its CI](.github/workflows/ci.yml) to cut its own releases (single repo-wide
semver from conventional commits; no in-tree version), and maintains the floating
`v1` / `v1.0` aliases consumers pin.
