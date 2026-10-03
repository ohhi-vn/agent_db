# Dialyzer findings this project tolerates, each with the reason it is here.
#
# The list is expected to shrink. An entry is removed when the code behind it is
# fixed; nothing is added to make a gate pass without a reason. Dialyzer reports
# an entry that no longer matches as an "unnecessary skip", so a stale one is
# visible rather than silent.
#
# Locations are project-relative, as Dialyxir wants them.

[
  # `AgentDb.Application.worker_specs/0` re-checks that the worker count is a
  # positive integer before it builds a pool out of it. Dialyzer trusts
  # `Config.job_workers/0`'s spec, which already says `pos_integer()`, and so
  # reports the guard as unreachable. The value comes from application
  # environment, which is outside the type system, so the check stays: it is
  # validation of external configuration, not dead code.
  {"lib/agent_db/application.ex", :pattern_match, 82},

  # A module-level `false` pattern that can never match a `true` value, reported
  # against `AgentDb.Application` and `AgentDb.Runtime` with no line or column.
  # It is not attributable to a construct in either module: it survives removing
  # `@moduledoc false`, and a synthetic module carrying the same attribute does
  # not reproduce it. Both are composition-root modules that the supervision
  # tree names directly, which is the only property they share that is not
  # ordinary. No code change is justified against a finding whose cause cannot
  # be located; drop these entries if a Dialyzer release stops reporting them.
  {"lib/agent_db/application.ex", :pattern_match, 1},
  {"lib/agent_db/runtime.ex", :pattern_match, 1}
]