# berth deploy payload — the published contract body (v1).
#
# Single source of truth for the body shape: berth-notify builds the POSTed body
# from this filter, and CI validates this same filter's output against
# ../schema/berth-payload.v1.json — so the action's wire format and the schema
# (which the host vendors) can't silently drift apart.
#
# `v` is the contract version, fixed here (not a caller input). Bump it only on a
# breaking body change, so the runner can branch on it.
{
  v: 1,
  repo: $repo,
  ref: $ref,
  instance: $instance,
  host_prefix: $host_prefix,
  tag: $tag,
  action: $action,
  secrets: $secrets
}
