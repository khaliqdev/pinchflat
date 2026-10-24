defmodule Pinchflat.Logs.LogBuffer do
  @moduledoc """
  Additive Logger backend capturing the app's own log lines into a bounded
  in-memory ETS ring buffer (ROADMAP Phase 5.1) and notifying the /logs
  viewer over a throttled `log_buffer` PubSub topic. Registered alongside
  `:console` in config.exs, so console output (Docker logs) keeps flowing
  untouched and the buffer is purely additive - logs-since-boot.

  The architecture mirrors `DownloadProgress`: the buffer lives in a public
  named ETS table with no per-line process hop, so a chatty debug firehose
  costs one ETS insert per line. Classic-backend callbacks (init/handle_event/
  handle_call) are gen_event callbacks that run inside Logger's manager
  process - Logger.Backends.Handler bridges Erlang events to them - so backend
  traffic is serialized exactly like the console backend's own formatting,
  and the public table lets `record/3` injections from any process interleave
  safely. The GenServer itself is nearly idle: it only owns the table, which
  is why the module is ALSO started as an application child - the
  `config :logger, backends:` registration only attaches the handler.

  Hard rules (spec): this module NEVER logs from inside itself (it is the
  logging sink - logging here would recurse), and every failure in the write
  path is swallowed - logging infrastructure can never take the app down.

  Rows are `{seq, timestamp, level, message, metadata, source}` - the spec's
  `{seq, time, level, message, metadata}` plus a `source` label derived for
  the by-worker/module filter. `source` prefers Logger metadata
  (`:worker`/`:module`/`:repo`), but this app's workers embed their identity
  in message text ("#{__MODULE__} discarded: ...", "[command_wrapper]: ...")
  and Oban's default telemetry logger JSON-encodes its worker field into the
  message, so the message-text derivation is what actually classifies
  worker traffic today.

  Messages are redacted before they enter the buffer: basic-auth URLs,
  query-string credentials (YouTube API keys, tokens, passwords) and
  Authorization header values get the masking treatment like every other
  credential surface in the app.

  The buffer holds the last `LOG_BUFFER_LINES` lines (default 5,000,
  ~1 MB), re-read from the environment on reset so tests (and the deployment
  env) can tune it without a recompile.
  """

  use GenServer

  @table :log_buffer
  @broadcast_topic "log_buffer"
  # One flush per interval no matter how many lines arrive - the viewer
  # catches up by seq on every tick, so a burst can never flood the websocket
  @broadcast_interval_ms 500
  @default_buffer_lines 5_000
  # Over-long lines are clamped so one pathological yt-dlp blob can't blow
  # up the buffer's memory budget (~1 MB at 5k lines) or the websocket
  @max_line_chars 4_000

  @levels [:debug, :info, :warning, :error]
  @secret_query_keys "api[_-]?key|apikey|key|token|access[_-]?token|refresh[_-]?token|password|secret|client[_-]?secret"

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Writes one log line into the buffer. This is the backend's `handle_event/2`
  path and doubles as the test-injection API (tests run at logger level
  `:critical`, so real events rarely reach the buffer).

  Never raises and never logs: a failure drops the line instead of taking
  down the logging pipeline or the process that happened to log.

  Returns :ok
  """
  def record(level, message, metadata \\ %{}) do
    do_record(level, message, metadata, now_timestamp())
  end

  @doc """
  Returns every buffered line, oldest first, as entry maps with a
  console-formatted `line` field. Bounded by the buffer cap.

  Returns list(map())
  """
  def all do
    if table_exists?() do
      :ets.select(@table, [{{:"$1", :_, :_, :_, :_, :_}, [{:is_integer, :"$1"}], [:"$_"]}])
      |> Enum.map(&to_entry/1)
    else
      []
    end
  end

  @doc """
  Returns buffered lines newer than `seq`, oldest first. Used by the viewer
  to catch up on each broadcast tick without re-reading the whole buffer.

  Returns list(map())
  """
  def since(seq) do
    if table_exists?() do
      :ets.select(@table, [
        {{:"$1", :_, :_, :_, :_, :_}, [{:is_integer, :"$1"}, {:>, :"$1", seq}], [:"$_"]}
      ])
      |> Enum.map(&to_entry/1)
    else
      []
    end
  end

  @doc """
  Returns the newest `count` entries, oldest first.

  Returns list(map())
  """
  def recent(count) do
    all()
    |> Enum.take(-count)
  end

  @doc """
  Per-level line counts across the whole buffer - the "3 errors since boot"
  numbers the level chips display. Missing levels default to 0.

  Returns map()
  """
  def counts do
    if table_exists?() do
      :ets.select(@table, [{{:"$1", :_, :"$3", :_, :_, :_}, [{:is_integer, :"$1"}], [:"$3"]}])
      |> Enum.frequencies_by(& &1)
    else
      %{}
    end
    |> Map.merge(Map.new(@levels, fn level -> {level, 0} end), fn _level, counted, _default -> counted end)
  end

  @doc """
  Distinct source labels (workers/modules) present in the buffer - the
  source filter chips for the viewer. Sorted, nil-less.

  Returns list(String.t())
  """
  def sources do
    if table_exists?() do
      :ets.select(@table, [{{:"$1", :_, :_, :_, :_, :"$6"}, [{:is_integer, :"$1"}], [:"$6"]}])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  end

  @doc """
  Number of buffered log lines.

  Returns non_neg_integer()
  """
  def total do
    if table_exists?() do
      :ets.select_count(@table, [{{:"$1", :_, :_, :_, :_, :_}, [{:is_integer, :"$1"}], [true]}])
    else
      0
    end
  end

  @doc """
  Deletes all buffered lines and reseeds the bookkeeping rows. Test-setup
  hook in the spirit of `DownloadProgress.reset!/0`.

  Returns :ok
  """
  def reset! do
    if table_exists?() do
      :ets.delete_all_objects(@table)
      ensure_bookkeeping_rows()
    end

    :ok
  end

  @doc """
  Formats one stored row/entry like the console formatter
  ("$date $time $metadata[$level] | $message") so the viewer and the export
  read like `docker logs`.

  Returns String.t()
  """
  def format_line({seq, timestamp, level, message, metadata, _source}) when is_integer(seq) do
    metadata_string = format_metadata(metadata)

    "#{format_timestamp(timestamp)} #{metadata_string}[#{level}] | #{message}"
  end

  def format_line(%{line: line}), do: line

  @doc """
  Masks token-bearing text: basic-auth URLs, query-string / bare / JSON-body
  credentials (YouTube API keys, tokens, passwords), free-standing AIza…
  API keys, and Authorization header values. Public so the redaction pass
  can be asserted directly.

  Returns String.t()
  """
  def redact(message) when is_binary(message) do
    # Regex.replace/4 is (regex, subject, replacement), so the piped subject
    # must be threaded through `then` - piping it straight in would make the
    # SUBJECT the first argument and every pass would raise FunctionClauseError
    message
    |> then(&Regex.replace(~r{(://[^:/\s@]+:)[^/\s@]+(@)}, &1, "\\1****\\2"))
    |> then(&Regex.replace(~r{([?&\s]|^)(#{@secret_query_keys})=([^&\s"']+)}i, &1, "\\1\\2=****"))
    |> then(&Regex.replace(~r/\bAIza[0-9A-Za-z_-]{10,}\b/, &1, "AIza****"))
    |> then(&Regex.replace(~r{"((?:#{@secret_query_keys}))"\s*:\s*"[^"]*"}i, &1, "\"\\1\": \"****\""))
    # Phoenix's inspect style, as logged from LiveView params: "_csrf_token" => "..."
    |> then(&Regex.replace(~r{("[^"]*(?:#{@secret_query_keys})[^"]*")\s*=>\s*"[^"]*"}i, &1, "\\1 => \"****\""))
    |> then(&Regex.replace(~r{(authorization["']?\s*[:=]\s*)("?)(bearer|basic)\s+\S+}i, &1, "\\1\\2\\3 ****"))
  end

  def redact(other), do: other

  # Server (backend) callbacks

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:ordered_set, :public, :named_table, read_concurrency: true])
    end

    ensure_bookkeeping_rows()

    {:ok, %{}}
  end

  # gen_event invokes this in Logger's manager process (Logger.Backends.Watcher
  # only supervises the registration), so the work here is serialized with the
  # console backend's own formatting - and a raising callback would get this
  # handler REMOVED from the manager, which is why do_record/4 swallows
  # everything. The event is the classic backend shape
  # {level, gl, {Logger, msg, ts, md}} - Logger.Backends.Handler translates
  # Erlang :logger events into it, mapping :warning to the legacy :warn atom
  # (normalized back to :warning in write_line/4).
  # NOTE: handle_event/2 and the arity-2 handle_call/2 are Logger *backend*
  # callbacks, not GenServer ones (handle_call/3 doesn't exist here), so they
  # carry no @impl - there is no formal backend behaviour to implement.
  def handle_event({level, _gl, {Logger, message, timestamp, metadata}}, state) do
    do_record(level, message, metadata, timestamp)

    {:ok, state}
  end

  # Logger.flush/0 sends :flush to every backend; swallow it like the
  # console backend does so the pipeline never blocks on us
  def handle_event(:flush, state), do: {:ok, state}

  def handle_event(_event, state), do: {:ok, state}

  def handle_call(_message, state), do: {:ok, :ok, state}

  # GenServer shape for the table-owning process (the backend role never
  # delivers handle_info - the handler wrapper only calls handle_event/2)
  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  # Recording. Runs in whatever process reaches it - Logger's manager process
  # for backend events, the caller for record/3 injections - against the
  # public table; never raises, never logs.

  defp do_record(level, message, metadata, timestamp) do
    try do
      write_line(level, message, metadata, timestamp)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  # Logger.Backends.Handler (the Erlang -> classic-backend bridge) translates
  # an Erlang :warning to the LEGACY :warn atom, so every real
  # Logger.warning/1 call arrives here as :warn. Store one canonical level or
  # the viewer's :warning chip and counts can never match real warnings.
  defp normalize_level(:warn), do: :warning
  defp normalize_level(level), do: level

  defp write_line(level, message, metadata, timestamp) do
    level = normalize_level(level)

    if table_exists?() do
      # Clamp before redaction AND source classification so a pathological
      # line can't feed a huge string to the regexes or the JSON decode
      raw_message = message |> normalize_message() |> clamp_string()
      sanitized_metadata = sanitize_metadata(metadata)
      seq = :ets.update_counter(@table, :seq, 1, {:seq, 0})

      :ets.insert(@table, {
        seq,
        timestamp,
        level,
        redact(raw_message),
        sanitized_metadata,
        derive_source(raw_message, sanitized_metadata)
      })

      trim_to_cap(seq, current_cap())
      maybe_broadcast(seq)
    end

    :ok
  end

  # Each insert deletes exactly the one row that fell off the ring, so the
  # cap holds with O(1) work per line (seqs are contiguous via the counter)
  defp trim_to_cap(seq, cap) when seq > cap do
    :ets.delete(@table, seq - cap)
  end

  defp trim_to_cap(_seq, _cap), do: :ok

  # The broadcast is best-effort: early-boot lines may land before the
  # endpoint/PubSub exist, and losing a tick is harmless (the viewer fetches
  # by seq and mount-time reads cover everything buffered)
  defp maybe_broadcast(seq) do
    now = System.system_time(:millisecond)
    last_flush_at = flush_at()

    if now - last_flush_at >= @broadcast_interval_ms do
      :ets.insert(@table, {:flush_at, now})

      try do
        PinchflatWeb.Endpoint.broadcast(@broadcast_topic, "append", %{seq: seq})
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # Two writers (concurrent record/3 calls - backend callbacks themselves are
  # serialized on Logger's process) can race past the throttle window and both
  # broadcast; the viewer's seq-keyed catch-up makes duplicate ticks a no-op,
  # so this is deliberately lock-free
  defp flush_at do
    case :ets.lookup(@table, :flush_at) do
      [{:flush_at, at}] -> at
      [] -> 0
    end
  end

  defp ensure_bookkeeping_rows do
    :ets.insert_new(@table, {:seq, 0})
    # insert (not insert_new) for the flush marker so a reset! also re-arms
    # the broadcast throttle - deterministic for tests, harmless on restart
    :ets.insert(@table, {:flush_at, 0})
    # insert (not insert_new) so a reset! after an env change picks up the
    # new cap, and tests can shrink it directly through the public table
    :ets.insert(@table, {:cap, default_buffer_lines()})

    :ok
  end

  defp current_cap do
    case :ets.lookup(@table, :cap) do
      [{:cap, cap}] when is_integer(cap) and cap > 0 -> cap
      _ -> @default_buffer_lines
    end
  end

  defp default_buffer_lines do
    case Integer.parse(System.get_env("LOG_BUFFER_LINES", "5000")) do
      {lines, _} when lines > 0 -> lines
      _ -> @default_buffer_lines
    end
  end

  defp table_exists?, do: :ets.whereis(@table) != :undefined

  defp to_entry({seq, timestamp, level, message, metadata, source}) do
    %{
      seq: seq,
      time: timestamp,
      level: level,
      message: message,
      metadata: metadata,
      source: source,
      line: format_line({seq, timestamp, level, message, metadata, source})
    }
  end

  # Normalization. Logger messages may arrive as chardata (or worse), and the
  # viewer/search/export treat lines as UTF-8 strings.

  defp normalize_message(message) when is_binary(message) do
    # yt-dlp streams arbitrary bytes; re-decode invalid UTF-8 as latin1 so
    # downstream String/grapheme work (and Jason) never choke on it
    if String.valid?(message), do: message, else: :unicode.characters_to_binary(message, :latin1)
  end

  defp normalize_message(message) when is_list(message) do
    try do
      IO.iodata_to_binary(message)
    rescue
      _ -> Kernel.inspect(message)
    end
    |> normalize_message()
  end

  defp normalize_message(other), do: Kernel.inspect(other)

  defp clamp_string(string) do
    if String.length(string) > @max_line_chars do
      String.slice(string, 0, @max_line_chars)
    else
      string
    end
  end

  # Metadata is caller-supplied: keep scalar values (redacted), inspect
  # everything else, and bound the whole thing so crash dumps can't blow the
  # buffer's memory budget. Real Logger events arrive with a keyword LIST
  # (Logger.Backends.Handler does Map.to_list of the Erlang metadata and
  # prepends :erl_level), so pair-lists normalize to a map and request_id-
  # style metadata survives; anything else is treated as having none
  defp sanitize_metadata(metadata) when is_list(metadata) do
    if proper_pair_list?(metadata) do
      metadata |> Map.new() |> sanitize_metadata()
    else
      %{}
    end
  end

  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.take(20)
    |> Map.new(fn
      {key, value} when is_binary(value) -> {key, redact(clamp_string(normalize_message(value), 500))}
      {key, value} when is_number(value) or is_boolean(value) -> {key, value}
      {key, value} when is_atom(value) and not is_nil(value) -> {key, value}
      {key, value} -> {key, clamp_string(Kernel.inspect(value), 500)}
    end)
  end

  defp sanitize_metadata(_), do: %{}

  # Guarded recursion instead of Keyword.keyword?/1 so an improper (hostile)
  # list degrades to "no metadata" instead of raising past do_record's catch-all
  defp proper_pair_list?([{key, _value} | rest]) when is_atom(key), do: proper_pair_list?(rest)
  defp proper_pair_list?([]), do: true
  defp proper_pair_list?(_), do: false

  defp clamp_string(string, max_chars) do
    if String.length(string) > max_chars, do: String.slice(string, 0, max_chars), else: string
  end

  # Worker/module classification. Metadata is authoritative when present;
  # otherwise message text carries the identity in this app (and Oban's
  # default logger JSON-encodes it into the message). Unidentified lines
  # simply have no source and always show under "All".

  defp derive_source(raw_message, metadata) do
    metadata_source(metadata) || oban_source(raw_message) || message_source(raw_message)
  end

  defp metadata_source(%{} = metadata) do
    cond do
      metadata[:worker] -> short_name(metadata[:worker])
      metadata[:module] -> short_name(metadata[:module])
      metadata[:repo] -> "Ecto"
      true -> nil
    end
  end

  defp oban_source(message) when is_binary(message) do
    if String.starts_with?(message, "{") do
      case Phoenix.json_library().decode(message) do
        {:ok, %{"worker" => worker}} -> short_name(worker)
        _ -> nil
      end
    else
      nil
    end
  end

  defp oban_source(_), do: nil

  defp message_source(message) when is_binary(message) do
    cond do
      String.contains?(message, "[command_wrapper]:") ->
        "YtDlp"

      String.starts_with?(message, "Oban") or String.contains?(message, "[oban") ->
        "Oban"

      match = Regex.run(~r/^(?:Elixir\.)?Pinchflat(?:\.[A-Z][A-Za-z0-9_]*)+/, message) ->
        match |> List.first() |> String.split(".") |> List.last()

      Regex.match?(~r/^(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) /, message) ->
        "Phoenix"

      String.contains?(message, "QUERY OK") or String.contains?(message, "QUERY ERROR") ->
        "Ecto"

      true ->
        nil
    end
  end

  defp message_source(_), do: nil

  defp short_name(value) do
    value |> to_string() |> String.split(".") |> List.last()
  end

  defp now_timestamp do
    {{y, m, d}, {h, mi, s}} = :calendar.universal_time()

    {{y, m, d}, {h, mi, s, 0}}
  end

  # Rendering. Matches the console formatter's "$date $time $metadata[$level]
  # | $message" so the viewer reads like docker logs.

  defp format_metadata(metadata) do
    case Enum.map(metadata, fn {key, value} -> "#{key}=#{value}" end) do
      [] -> ""
      parts -> Enum.join(parts, " ") <> " "
    end
  end

  defp format_timestamp({{y, mo, d}, {h, mi, s, ms}}) do
    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B.~3..0B", [y, mo, d, h, mi, s, ms])
    |> IO.iodata_to_binary()
  end

  defp format_timestamp(_), do: ""
end
