# Deterministic Benchee scenarios for AgentDb core operations.
#
# Uses isolated temporary SQLite data and real storage with model-free paths
# (reads, listings, tree projection, keyword search, grep, find, writes,
# queue throughput). Vector
# and hybrid legs need models/sqlite-vec and are measured on their error path
# here; a warmed-model procedure on hosts with weights can extend these.
#
# Run: mix run bench/agent_db_bench.exs
# Baseline saved to bench/baseline.md with scenario inputs.
#
# NOTE: `mix run` autostarts the app before this script runs, so the data dir
# must be applied with a restart (setting env after boot is too late and
# pollutes ./data).

data_dir = Path.join(System.tmp_dir!(), "agent_db_bench_#{:erlang.unique_integer([:positive])}")
:ok = Application.stop(:agent_db)
Application.put_env(:agent_db, :data_dir, data_dir)
Application.put_env(:agent_db, :http_enabled, false)
{:ok, _} = Application.ensure_all_started(:agent_db)

for {id, _, _, _} <- Supervisor.which_children(AgentDb.Supervisor) do
  case id do
    {mod, _} when mod in [AgentDb.Workers.Embedding, AgentDb.Workers.Summarization] ->
      Supervisor.terminate_child(AgentDb.Supervisor, id)

    _ ->
      :ok
  end
end

# Seed deterministic documents.
for i <- 1..20 do
  :ok =
    AgentDb.write(
      "viking://resources/bench/doc#{i}.md",
      "benchmark content #{i} with keyword alpha"
    )
end

# A second, larger corpus for the scenarios whose cost follows the number of
# matches rather than the number of documents: an unbounded scan looks the same
# at 20 documents as at 20, which is what made the keyword bound invisible.
for i <- 1..1_000 do
  :ok =
    AgentDb.write(
      "viking://resources/bench_wide/doc#{i}.md",
      "wide corpus content #{i} with keyword beta"
    )
end

Benchee.run(
  %{
    "read" => fn -> AgentDb.read("viking://resources/bench/doc1.md") end,
    "list" => fn -> AgentDb.list("viking://resources/bench") end,
    "tree_projection" => fn -> AgentDb.tree("viking://resources/bench", 2) end,
    "keyword_search" => fn -> AgentDb.search("alpha", mode: :keyword, top_k: 10) end,
    "keyword_search_wide" => fn ->
      AgentDb.search("beta", mode: :keyword, scope: "viking://resources/bench_wide", top_k: 10)
    end,
    "grep" => fn -> AgentDb.grep("alpha", limit: 50) end,
    "find" => fn -> AgentDb.find("doc", scope: "viking://resources/bench", limit: 50) end,
    "hybrid_search_error_path" => fn -> AgentDb.search("alpha", mode: :hybrid, top_k: 10) end,
    "write" => fn ->
      AgentDb.write("viking://resources/bench/tmp.md", "tmp #{System.unique_integer()}")
    end,
    "queue_throughput" => fn -> AgentDb.queue_stats() end
  },
  time: 3,
  memory_time: 1,
  print: [fast_warning: false]
)

File.rm_rf!(data_dir)
