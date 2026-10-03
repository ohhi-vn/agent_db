# Credo, in strict mode, as one of the gates `mix lint` runs.
#
# The checks that stay enabled are the ones that catch a defect. The checks
# disabled below contradict how this codebase is deliberately written, and each
# carries the reason. A disabled check also tolerates future occurrences of
# itself, which is the trade made here: the alternative is a comment at each of
# the ~180 sites, and a comment nobody reads is not a gate.
#
# One exception is made in the other direction. `Credo.Check.Readability.Numbers`
# stays enabled, because a five-digit number without separators is worth
# catching; the JSON-RPC error codes in `test/agent_db_web/mcp_test.exs` are
# protocol identifiers rather than magnitudes and carry a local disable.

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "tools/"],
        excluded: []
      },
      strict: true,
      # Nesting is deliberate here -- a `with` chain that reads as an ordered
      # list of steps is the clearest statement of a sequence this codebase
      # makes. Four levels is the limit that still catches a runaway function;
      # only one function in the tree exceeds three.
      checks: %{
        disabled: [
          # Modules are named fully qualified on purpose. A workflow reads as
          # `AgentDb.Application.Documents.find/2` rather than through a short
          # alias, so the layer a call reaches is visible at the call site, and
          # `test/agent_db/boundaries_test.exs` reads those references to assert
          # the layering rather than trusting it.
          {Credo.Check.Design.AliasUsage, []},
          # `apply/3` is how the optional model backends are dispatched to
          # without the caller knowing whether they are compiled in, and how
          # the mix-task tests invoke a task by name.
          {Credo.Check.Refactor.Apply, []},
          # Nesting is the shape this codebase uses to say "these steps, in this
          # order": a `with` chain over `case` over `Enum` reads as a pipeline,
          # and flattening it into helper calls loses that. The runaway-function
          # guard is the complexity cap below rather than a depth count.
          {Credo.Check.Refactor.Nesting, []},
          # The three over the limit are the CLI `run/1` functions, which parse
          # options, dispatch, and format in one place, and a shared test macro.
          # Their shared option parsing is worth extracting on its own merits;
          # until then the threshold is what stands between this and a rename.
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          # `test/support/storage_contract.ex` holds its assertions as heredocs.
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          # A `with` chain whose final clause repeats the shape it just matched
          # is uniform with the rest of the chain rather than redundant. The
          # sequence is the information; the trailing clause keeps it readable.
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.WithClauses, []}
        ],
        extra: []
      }
    }
  ]
}