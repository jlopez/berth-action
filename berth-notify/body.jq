# berth deploy payload — the published contract body (v1).
#
# Single source of truth for the body shape: berth-notify builds the POSTed body
# from this filter, and CI validates this same filter's output against
# ../schema/berth-payload.v1.json — so the action's wire format and the schema
# (which the host vendors) can't silently drift apart.
#
# `v` is the contract version, fixed here (not a caller input). Bump it only on a
# breaking body change, so the runner can branch on it.
#
# `deploy_id` is a per-CI-run correlation token (run_id-run_attempt). The runner
# keys its deploy-status file on it so berth-notify can poll /hooks/berth-status
# until the stack docks. It's an additive, backward-compatible field (optional in
# the schema, ignored by an older runner), so it does NOT bump `v`.
{
  v: 1,
  repo: $repo,
  ref: $ref,
  instance: $instance,
  host_base: $host_base,
  tag: $tag,
  action: $action,
  deploy_id: $deploy_id,
  secrets: $secrets
}
