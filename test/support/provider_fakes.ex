defmodule AgentDb.Test.Script do
  @moduledoc false
  # Where the fakes keep the answers a test has scripted for them.
  #
  # Application env cannot hold a composite key, and a per-test process
  # dictionary would not be visible to the worker processes some of these
  # answers have to reach. A named table serves both cases, and is created on
  # first use so no test has to arrange it.

  @table :agent_db_test_script

  def put(scope, key, value) do
    ensure_table()
    :ets.insert(@table, {{scope, key}, value})
    :ok
  end

  def fetch(scope, key, default) do
    ensure_table()

    case :ets.lookup(@table, {scope, key}) do
      [{_entry, value}] -> value
      [] -> default
    end
  end

  def clear(scope) do
    ensure_table()
    :ets.match_delete(@table, {{scope, :_}, :_})
    :ok
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :public])
    end

    :ok
  end
end

defmodule AgentDb.Test.Fakes.Storage do
  @moduledoc false
  # A working storage provider, in memory.
  #
  # Two kinds of test use it, and they need different things from it. The
  # composition tests need a provider that behaves, so everything is held in
  # memory. The contract tests need a double they can script per callback. So
  # both are here: the in-memory store answers unless a callback has been
  # scripted for this test, and a script wins when there is one.
  #
  # It exists to answer one question the default provider cannot: when a
  # deployment points the store somewhere else, does the store still work? That
  # is a question about the workflows reaching storage only through the port, so
  # this provider implements enough of it to be exercised -- documents, the tree,
  # search, sessions, memories, and the queue -- with no database anywhere.
  #
  # It deliberately does not try to be a second SQLite. Where the contract's
  # invariants are about coordination between stores it holds the state in one
  # place, which is enough to show a workflow depends on the port rather than on
  # one database's behaviour.
  #
  # Any callback can be overridden per test with `stub/2`, which is how a failure
  # or an unusual answer gets injected.

  @behaviour AgentDb.Core.Storage

  alias AgentDb.URI, as: VikingURI

  @table :agent_db_fake_storage
  @keys [:documents, :memories, :messages, :hashes, :embeddings, :jobs]

  # A node reported for any URI, for a test about the port's shape rather than
  # about this provider's behaviour. Lives outside `@keys` so a reset between
  # tests does not take a stub a later test is relying on.
  @stub_key :stub_node

  # Two vectors this close are the same vector for practical purposes: the same
  # text, embedded deterministically.
  @identical 1.0e-9

  @impl true
  def child_specs(_opts), do: []

  @impl true
  def get_node(uri) do
    scripted(:get_node, {:ok, Map.get(documents(), uri) || stubbed_node(uri)})
  end

  @doc "Reports a node for any URI, shaped as a stored document."
  def set_stub_node(node) do
    ensure_table()
    :ets.insert(@table, {@stub_key, node})
  end

  defp stubbed_node(uri) do
    case :ets.lookup(@table, @stub_key) do
      [{_key, node}] -> Map.put(node, :uri, uri)
      [] -> nil
    end
  end

  @impl true
  def put_document(uri, content, opts) do
    with {:ok, _segments} <- VikingURI.parse(uri) do
      record(uri, content, opts)
      scripted(:put_document, :ok)
    end
  end

  @impl true
  def list_children(uri) do
    case Map.fetch(documents(), uri) do
      {:ok, %{kind: :dir}} -> {:ok, children_of(uri)}
      {:ok, _document} -> {:error, :not_found}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def remove_subtree(uri) do
    case Map.fetch(documents(), uri) do
      :error ->
        scripted(:remove_subtree, {:error, :not_found})

      {:ok, %{kind: :dir}} when uri == "viking://" ->
        scripted(:remove_subtree, {:error, :is_root})

      _present ->
        # Every store keyed by URI, in one step: the removals that have to
        # agree with each other are the point of the contract.
        put(:documents, Map.drop(documents(), subtree(uri)), [])
        put(:memories, Map.drop(memories(), subtree(uri)), [])
        put(:hashes, Map.drop(hashes(), subtree_map_keys(uri)), [])
        put(:embeddings, Map.drop(embeddings(), subtree(uri)), [])
        put(:jobs, Enum.reject(jobs(), fn job -> uri_matches?(job.payload["uri"], uri) end), [])
        scripted(:remove_subtree, :ok)
    end
  end

  # In memory the replacement is one step by construction, which is what lets a
  # test ask what a *provider* owes here rather than what SQLite owes: the old
  # subtree goes, the files arrive at their paths, and each is queued for the
  # same work a write queues.
  #
  # A script may answer instead of doing the work -- a function of the URI and
  # files, so a test can fail one skill of an import and not the others.
  @doc """
  Replaces the subtree at `uri` with `files`, for real.

  `replace_skill/2` answers with whatever a test has scripted, which is how a
  fault is injected; this is the work itself, so a script can let one import of a
  collection through and refuse the next.
  """
  @spec do_replace_skill(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def do_replace_skill(uri, files) do
    replaced? = Map.has_key?(documents(), uri)
    put(:documents, Map.drop(documents(), subtree(uri)), [])
    put(:memories, Map.drop(memories(), subtree(uri)), [])
    put(:embeddings, Map.drop(embeddings(), subtree(uri)), [])
    put(:jobs, Enum.reject(jobs(), fn job -> uri_matches?(job.payload["uri"], uri) end), [])

    outcome =
      Enum.reduce_while(files, :ok, fn file, :ok ->
        case put_skill_file(uri, file) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case outcome do
      :ok -> {:ok, %{replaced: replaced?, files: length(files)}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def replace_skill(uri, files) do
    with {:ok, _segments} <- VikingURI.parse(uri) do
      case scripted(:replace_skill, :replace) do
        :replace -> do_replace_skill(uri, files)
        fun when is_function(fun, 2) -> fun.(uri, files)
        result -> result
      end
    end
  end

  defp put_skill_file(uri, %{path: path, content: content}) do
    {:ok, segments} = VikingURI.parse(uri)
    target = VikingURI.build(segments ++ path)

    with :ok <- record(target, content, []),
         {:ok, _job} <- enqueue_job(:embed, %{uri: target, content: content}) do
      :ok
    end
  end

  @impl true
  def put_layer_result(job_id, uri, layer, text) do
    # Fenced on the node, exactly as the default provider is: a result computed
    # before a removal must not bring the URI back.
    case Map.fetch(documents(), uri) do
      {:ok, %{kind: :doc} = document} ->
        put(:documents, Map.put(documents(), uri, %{document | layer => text}), :ok)
        finish(job_id, :stored)

      _absent ->
        discard(job_id)
    end
  end

  @impl true
  def put_embedding_result(job_id, uri, embedding) do
    # Fenced on the node, exactly as the default provider is: a result computed
    # before a removal must not bring the URI back.
    case Map.fetch(documents(), uri) do
      {:ok, %{kind: :doc}} ->
        put(:embeddings, Map.put(embeddings(), uri, embedding), :ok)
        finish(job_id, :stored)

      _absent ->
        discard(job_id)
    end
  end

  # Storing a result and finishing the job that produced it are one outcome, so
  # a stored result with an unfinished job would be redone.
  defp finish(job_id, outcome) do
    case complete_job(job_id) do
      :ok -> {:ok, outcome}
      {:error, _} = err -> err
    end
  end

  @impl true
  def search_keyword(term, scope) do
    needle = String.downcase(term)

    hits =
      for {uri, document} <- documents(),
          uri_matches?(uri, scope),
          document.kind == :doc,
          matches?(document.content, needle) or matches?(document.abstract, needle) or
            matches?(document.overview, needle) do
        document
      end

    scripted(:search_keyword, {:ok, hits})
  end

  @impl true
  def search_vector(query, _top_k, scope) do
    # Ranked by nearest neighbour over the vectors themselves, which is what the
    # port hands over: bytes, not text. Exact match is the only similarity a
    # double can implement honestly, so identical text finds itself and
    # different text does not -- enough to show a vector search is scoped and
    # answered from the index rather than from the text.
    hits =
      for {uri, embedding} <- embeddings(),
          uri_matches?(uri, scope),
          distance(query, embedding) <= @identical do
        %{
          uri: uri,
          content: content_at(uri),
          abstract: abstract_at(uri),
          overview: overview_at(uri),
          score: 1.0
        }
      end

    scripted(:search_vector, {:ok, hits})
  end

  # Both are float32 vectors of the same length, so the distance is the sum of
  # squared differences read back out of the bytes. Vectors of different lengths
  # cannot be compared, and count as no match at all.
  defp distance(left, right) when byte_size(left) == byte_size(right) do
    for {<<a::float-32, b::float-32>>, <<l::float-32, r::float-32>>} <- floats(left, right) do
      (a - l) * (a - l) + (b - r) * (b - r)
    end
    |> Enum.sum()
  end

  defp distance(_left, _right), do: :infinity

  defp floats(
         <<a::float-32, b::float-32, rest::binary>>,
         <<l::float-32, r::float-32, other::binary>>
       ) do
    [{{a, b}, {l, r}} | floats(rest, other)]
  end

  defp floats(<<>>, <<>>), do: []

  defp content_at(uri), do: get_in(documents(), [uri, :content])
  defp abstract_at(uri), do: get_in(documents(), [uri, :abstract])
  defp overview_at(uri), do: get_in(documents(), [uri, :overview])

  @impl true
  def create_session, do: scripted(:create_session, {:ok, "fake-session"})

  @impl true
  def append_message(session_id, role, content) do
    put(
      :messages,
      Map.update(messages(), session_id, [%{seq: 0, role: role, content: content}], fn existing ->
        [%{seq: length(existing), role: role, content: content} | existing]
      end),
      :ok
    )
  end

  @impl true
  def get_session(session_id) do
    case scripted(:get_session, {:ok, messages()[session_id] || []}) do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      other -> other
    end
  end

  @impl true
  def commit_hash(session_id, destination), do: {:ok, hashes()[{session_id, destination}]}

  @impl true
  def put_commit(session_id, destination, hash, content) do
    with {:ok, _segments} <- VikingURI.parse(destination) do
      record(destination, content, [])
      put(:hashes, Map.put(hashes(), {session_id, destination}, hash), :ok)
    end
  end

  @impl true
  def put_memory(uri, value, confidence, source) do
    with {:ok, _segments} <- VikingURI.parse(uri) do
      record(uri, value, [])

      assertion = %{
        id: System.unique_integer([:positive]),
        uri: uri,
        value: value,
        confidence: confidence * 1.0,
        source: source,
        status: :active,
        supersedes: nil,
        updated_at: System.system_time(:millisecond)
      }

      put(:memories, Map.update(memories(), uri, [assertion], &supersede(&1, assertion)), :ok)
    end
  end

  @impl true
  def recall_memories(prefix, term, statuses) do
    rows =
      for {uri, assertions} <- memories(),
          uri_matches?(uri, prefix),
          assertion <- assertions,
          assertion.status in statuses,
          term == nil or matches?(assertion.value, String.downcase(term)) do
        assertion
      end

    scripted(:recall_memories, {:ok, Enum.sort_by(rows, & &1.confidence, :desc)})
  end

  @impl true
  def memory_recorded?(uri), do: scripted(:memory_recorded?, {:ok, Map.has_key?(memories(), uri)})

  @impl true
  def enqueue_job(kind, payload) do
    # Carries the fields a claim reports, so a job read back looks the way a
    # durable one does rather than a bare record of what was asked for.
    job = %{
      id: System.unique_integer([:positive]),
      kind: kind,
      payload: serialise(payload),
      status: :pending,
      attempts: 0,
      max_attempts: 5
    }

    put(:jobs, [job | jobs()], {:ok, job.id})
  end

  # A real queue serialises its payload, so a job read back has string keys
  # whatever was written into it. A provider that returned it as given would
  # hide a workflow reaching for a key that a persisted job does not have.
  defp serialise(payload) do
    for {key, value} <- payload, into: %{}, do: {to_string(key), value}
  end

  @impl true
  def cancel_jobs(uri) do
    put(:jobs, Enum.reject(jobs(), fn job -> uri_matches?(job.payload["uri"], uri) end), :ok)
  end

  @impl true
  def count_jobs(uri, statuses) do
    Enum.count(jobs(), fn job ->
      uri_matches?(job.payload["uri"], uri) and job.status in statuses
    end)
  end

  @impl true
  def dequeue_job(kinds) do
    case Enum.find(jobs(), &(&1.status == :pending and &1.kind in kinds)) do
      nil ->
        {:error, :empty}

      job ->
        claimed = %{job | status: :running, attempts: job.attempts + 1}
        put(:jobs, Enum.map(jobs(), &if(&1.id == job.id, do: claimed, else: &1)), [])
        {:ok, claimed}
    end
  end

  @impl true
  def complete_job(job_id) do
    put(:jobs, Enum.map(jobs(), &if(&1.id == job_id, do: %{&1 | status: :done}, else: &1)), :ok)
  end

  @impl true
  def fail_job(job_id) do
    update_job(job_id, &%{&1 | status: :failed})
  end

  @impl true
  def defer_job(job_id, _delay_ms) do
    update_job(job_id, &%{&1 | status: :pending, attempts: max(&1.attempts - 1, 0)})
  end

  @impl true
  def reset_running_jobs,
    do: put(:jobs, Enum.map(jobs(), &%{&1 | status: :pending, attempts: 0}), :ok)

  @impl true
  def queue_stats do
    counts = Enum.frequencies_by(jobs(), & &1.status)
    scripted(:queue_stats, {:ok, counts})
  end

  @impl true
  def healthy?, do: scripted(:healthy?, true)

  # -- test control --

  @doc "Answers `callback` with `result` for the rest of the test."
  def stub(callback, result) when is_atom(callback) and not is_nil(callback) do
    AgentDb.Test.Script.put(:fake_storage, callback, result)
  end

  @doc "Forgets everything recorded, so one test does not see another's writes."
  def reset do
    for key <- @keys, do: put(key, initial(key), [])
    :ok
  end

  @doc "The jobs recorded, for a test that needs to see the queue."
  def recorded_jobs, do: state(:jobs)

  defp scripted(callback, default),
    do: AgentDb.Test.Script.fetch(:fake_storage, callback, default)

  defp state(key) do
    ensure_table()
    :ets.lookup_element(@table, key, 2)
  end

  defp put(key, value, result) do
    ensure_table()
    :ets.insert(@table, {key, value})
    result
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table])
      for key <- @keys, do: put(key, initial(key), [])
    else
      :ok
    end
  end

  # The two collections that start empty as a list and the rest as a map.
  defp initial(key) when key in [:jobs], do: []
  defp initial(_key), do: %{}

  defp documents do
    ensure_table()
    state(:documents)
  end

  defp memories, do: state(:memories)
  defp messages, do: state(:messages)
  defp hashes, do: state(:hashes)
  defp embeddings, do: state(:embeddings)
  defp jobs, do: state(:jobs)

  # A document, and every directory above it, so the tree a write implies
  # exists.
  defp record(uri, content, opts) do
    ensure_directories(uri)

    document = %{
      uri: uri,
      parent_uri: parent_of(uri),
      name: name_of(uri),
      kind: :doc,
      content: content,
      abstract: opts[:abstract],
      overview: opts[:overview]
    }

    put(:documents, Map.put(documents(), uri, document), :ok)
  end

  defp ensure_directories(uri) do
    segments = elem(VikingURI.parse(uri), 1)

    for take <- 0..(length(segments) - 1) do
      directory = VikingURI.build(Enum.take(segments, take))

      put(
        :documents,
        Map.put_new(documents(), directory, %{
          uri: directory,
          parent_uri: parent_of(directory),
          name: name_of(directory),
          kind: :dir,
          content: nil,
          abstract: nil,
          overview: nil
        }),
        []
      )
    end

    :ok
  end

  # The names of a directory's direct children, which is the next segment of
  # each node one level below it.
  defp children_of(uri) do
    depth = depth_of(uri)

    for child <- Map.keys(documents()),
        child != uri,
        at_depth(child, depth),
        {_, name} <- [
          segments_of(child) |> Enum.split(depth) |> then(fn {_, [name | _]} -> {child, name} end)
        ] do
      name
    end
  end

  defp depth_of("viking://"), do: 0
  defp depth_of(uri), do: uri |> segments_of() |> length()

  defp at_depth(child, depth), do: length(segments_of(child)) == depth + 1

  defp segments_of(child) do
    case VikingURI.parse(child) do
      {:ok, segments} -> segments
      _other -> []
    end
  end

  defp name_of(uri) do
    case VikingURI.parse(uri) do
      {:ok, []} -> ""
      {:ok, segments} -> List.last(segments)
      _other -> ""
    end
  end

  defp parent_of(uri) do
    case VikingURI.parse(uri) do
      {:ok, []} -> nil
      {:ok, segments} -> VikingURI.build(Enum.drop(segments, -1))
      _other -> nil
    end
  end

  # The URI and everything beneath it. Removal is a subtree operation, so a
  # descendant is in scope even though it is not the URI itself.
  defp subtree(uri) do
    prefix = String.trim_trailing(uri, "/") <> "/"

    for candidate <- Map.keys(documents()),
        candidate == uri or String.starts_with?(candidate, prefix),
        do: candidate
  end

  # Commit bookkeeping is keyed by (session, destination), so a removal has to
  # match on the destination half rather than drop the whole entry blindly.
  defp subtree_map_keys(uri) do
    for {{_session, destination} = key, _hash} <- hashes(),
        uri_matches?(destination, uri),
        do: key
  end

  defp matches?(nil, _needle), do: false

  defp matches?(text, needle),
    do: text |> Kernel.||("") |> String.downcase() |> String.contains?(needle)

  # A scope matches a URI or anything beneath it. The scope arrives as a
  # subtree prefix, so trailing separators are normalized rather than assumed
  # either way.
  defp uri_matches?(_uri, nil), do: true

  defp uri_matches?(uri, scope) do
    prefix = String.trim_trailing(scope, "/")

    uri == prefix or String.starts_with?(uri, prefix <> "/")
  end

  defp discard(job_id) do
    complete_job(job_id)
    {:ok, :discarded}
  end

  defp supersede(prior, successor) do
    superseded =
      Enum.map(prior, fn %{status: :active} = row ->
        %{row | status: :superseded, supersedes: successor.id}
      end)

    superseded ++ [successor]
  end

  defp update_job(job_id, change) do
    put(:jobs, Enum.map(jobs(), &if(&1.id == job_id, do: change.(&1), else: &1)), :ok)
  end
end

defmodule AgentDb.Test.Fakes.Storage.Unimplemented do
  @moduledoc false
  # A module selected as a storage provider that implements nothing. Startup
  # must reject it rather than substituting a working adapter, so a
  # misconfigured deployment fails loudly instead of quietly serving from the
  # default.
end

defmodule AgentDb.Test.Fakes.Inference do
  @moduledoc false
  # A deterministic inference provider: no models, no weights, no downloads.
  #
  # Embeddings are derived from the text itself, so "same input, same
  # embedding" is real rather than asserted, and distinct inputs produce
  # distinct vectors.

  @behaviour AgentDb.Core.Inference

  @scope :fake_inference
  @dim 4

  @impl true
  def child_specs(_opts), do: []

  @impl true
  def embed(texts), do: scripted(:embed, {:ok, Enum.map(texts, &embedding/1)})

  @impl true
  def summarize(prompt, _opts), do: scripted(:summarize, {:ok, "summary of " <> prompt})

  @impl true
  def model_status, do: scripted(:model_status, default_status())

  @doc "Scripts the next `embed/1` answer, e.g. `{:error, :model_loading}`."
  def stub_embed(result), do: AgentDb.Test.Script.put(@scope, :embed, result)

  @doc "Scripts the next `summarize/2` answer."
  def stub_summarize(result), do: AgentDb.Test.Script.put(@scope, :summarize, result)

  @doc "Dimensionality of the vectors this provider returns."
  def dim, do: @dim

  defp scripted(capability, default), do: AgentDb.Test.Script.fetch(@scope, capability, default)

  defp default_status do
    %{
      embedding: %{loaded: true, state: :ready, model: "fake-embedder", dim: @dim},
      llm: %{loaded: true, state: :ready, model: "fake-summarizer", params: "0B"},
      queue: %{pending: 0}
    }
  end

  # Four float32 values derived from the text, so equal text compares equal and
  # different text does not.
  defp embedding(text) do
    :erlang.iolist_to_binary(binary_part(:crypto.hash(:sha256, text), 0, 16))
  end
end

defmodule AgentDb.Test.Fakes.Transport do
  @moduledoc false
  # A transport that starts a probe instead of a server, so the composition
  # boundary can be exercised with no Phoenix in the picture at all.

  @behaviour AgentDb.Core.Transport

  @impl true
  def enabled?, do: Application.get_env(:agent_db, :fake_transport_enabled, true)

  @impl true
  def child_specs(_opts), do: [{AgentDb.Test.Fakes.Transport.Probe, []}]

  defmodule Probe do
    @moduledoc false
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts), do: {:ok, opts}
  end
end
