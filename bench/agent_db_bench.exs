# Deterministic Benchee scenarios for AgentDb core operations.
#
# Uses isolated temporary SQLite data and real storage with model-free paths
# (reads, tree projection, keyword search, writes, queue throughput). Vector
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

Benchee.run(
  %{
    "read" => fn -> AgentDb.read("viking://resources/bench/doc1.md") end,
    "tree_projection" => fn -> AgentDb.tree("viking://resources/bench", 2) end,
    "keyword_search" => fn -> AgentDb.search("alpha", mode: :keyword, top_k: 10) end,
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
