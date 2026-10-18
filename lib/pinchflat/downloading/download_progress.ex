defmodule Pinchflat.Downloading.DownloadProgress do
  @moduledoc """
  Tracks per-media-item download progress parsed from yt-dlp's streamed
  progress lines and broadcasts throttled updates for the live UI.

  Progress rows live in a public named ETS table owned by this GenServer so
  `record_line/2` (which runs inside the download worker's port loop) can
  write without going through a process. The server itself is nearly idle:
  it only sweeps rows that have gone stale, which covers workers that were
  SIGKILLed mid-download and never got to clean up after themselves.

  `record_line/2` is exception-free by construction: the progress template
  string is an external contract and numeric fields may arrive humanized
  ("45.32MiB") or as sentinels ("Unknown"/"NA"), and a raising parse must
  never kill a live download.
  """

  use GenServer

  require Logger

  alias Pinchflat.Utils.NumberUtils

  @table :download_progress
  @broadcast_topic "download_progress"
  # One broadcast per item per interval, no matter how many lines arrive
  @broadcast_interval_ms 500
  # Rows older than this are assumed orphaned (killed worker) and swept
  @stale_ttl_ms 600_000
  @sweep_interval_ms 60_000

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Parses one yt-dlp progress line and records/broadcasts it for the given
  media item. Non-JSON lines (warnings, blanks) are ignored. Never raises -
  a bad line is logged and dropped instead of killing the download.

  Returns :ok
  """
  def record_line(media_item_id, line) when is_binary(line) do
    try do
      record_parsed_line(media_item_id, line)
    rescue
      e ->
        Logger.error("""
        Download progress recording raised on line - skipping it:
        #{Exception.format(:error, e, __STACKTRACE__)}
        """)
    end

    :ok
  end

  def record_line(_media_item_id, _line), do: :ok

  @doc """
  Returns the recorded progress row for a media item (or nil).

  Returns map() | nil
  """
  def get(media_item_id) do
    if table_exists?() do
      case :ets.lookup(@table, media_item_id) do
        [{^media_item_id, row}] -> row
        [] -> nil
      end
    end
  end

  # The table is created by this module's own GenServer. Anything can read it
  # from a process that outlived a restart (code-reloaded LiveViews, the test
  # sandbox) - a missing table means "no progress recorded", never a crash
  defp table_exists?, do: :ets.whereis(@table) != :undefined

  @doc """
  Returns a %{media_item_id => %{percent, speed, eta}} snapshot of all
  recorded rows. Used by the LiveView on mount.

  Returns map()
  """
  def snapshot do
    if table_exists?() do
      @table
      |> :ets.tab2list()
      |> Map.new(fn {id, row} -> {id, %{percent: row.percent, speed: row.speed, eta: row.eta}} end)
    else
      %{}
    end
  end

  @doc """
  Deletes the progress row for a media item. Idempotent.

  Returns :ok
  """
  def clear(media_item_id) do
    if table_exists?(), do: :ets.delete(@table, media_item_id)

    :ok
  end

  @doc """
  Deletes all progress rows. Test-setup hook in the spirit of
  `RateLimit.clear!/0`.

  Returns :ok
  """
  def reset! do
    :ets.delete_all_objects(@table)

    :ok
  end

  @doc """
  Deletes rows whose updated_at is older than `@stale_ttl_ms`. Runs on the
  GenServer's schedule but is safe to call from anywhere (tests use it to
  exercise the sweep directly).

  Returns non_neg_integer()
  """
  def sweep do
    cutoff = System.system_time(:millisecond) - @stale_ttl_ms

    match_spec = [
      {{:_, :"$1"}, [{:is_map, :"$1"}, {:<, {:map_get, :updated_at, :"$1"}, cutoff}], [true]}
    ]

    :ets.select_delete(@table, match_spec)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    Process.send_after(self(), :sweep, @sweep_interval_ms)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    deleted = sweep()

    if deleted > 0, do: Logger.debug("Download progress sweep removed #{deleted} stale rows")

    Process.send_after(self(), :sweep, @sweep_interval_ms)

    {:noreply, state}
  end

  # Parsing and recording. Runs in the calling (worker) process against the
  # public table.

  defp record_parsed_line(media_item_id, line) do
    with {:ok, decoded} <- Phoenix.json_library().decode(line),
         %{} = progress <- decoded do
      downloaded = safe_number(progress["downloaded_bytes"])
      total = safe_number(progress["total_bytes"]) || safe_number(progress["total_bytes_estimate"])
      speed = safe_string(progress["_speed_str"]) || safe_string(progress["speed_str"])
      eta = safe_string(progress["_eta_str"]) || safe_string(progress["eta_str"])
      percent = compute_percent(downloaded, total)

      now = System.system_time(:millisecond)
      previous = get(media_item_id)
      last_broadcast_at = previous && previous.last_broadcast_at
      should_broadcast = now - (last_broadcast_at || 0) >= @broadcast_interval_ms

      row = %{
        percent: percent,
        speed: speed,
        eta: eta,
        updated_at: now,
        last_broadcast_at: if(should_broadcast, do: now, else: last_broadcast_at)
      }

      if table_exists?(), do: :ets.insert(@table, {media_item_id, row})

      if should_broadcast do
        PinchflatWeb.Endpoint.broadcast(@broadcast_topic, "progress", %{
          media_item_id: media_item_id,
          percent: percent,
          speed: speed,
          eta: eta
        })
      end
    else
      _ -> :ok
    end
  end

  # Numeric fields are emitted by our %(...{...})j template so they arrive as
  # JSON numbers, but the template is an external contract: tolerate clean
  # numeric strings and drop anything humanized ("45.32MiB") or sentinel.
  defp safe_number(value) when is_number(value), do: value

  defp safe_number(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed in ["", "NA", "Unknown"] ->
        nil

      true ->
        try do
          String.to_integer(trimmed)
        rescue
          ArgumentError ->
            try do
              String.to_float(trimmed)
            rescue
              ArgumentError -> nil
            end
        end
    end
  end

  defp safe_number(_), do: nil

  # yt-dlp humanizes _speed_str/_eta_str and pads them (" Unknown B/s"), and
  # uses "Unknown"/"NA" before the first measurement
  defp safe_string(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" or trimmed == "NA" or String.starts_with?(trimmed, "Unknown"), do: nil, else: trimmed
  end

  defp safe_string(_), do: nil

  # nil percent means "indeterminate" in the UI. The total > 0 guard also
  # covers division by zero for zero-byte totals. The final * 1.0 keeps the
  # value a float even when clamping snaps it to an integer bound.
  defp compute_percent(downloaded, total) when is_number(downloaded) and is_number(total) and total > 0 do
    downloaded
    |> Kernel./(total)
    |> Kernel.*(100)
    |> Float.round(1)
    |> NumberUtils.clamp(0, 100)
    |> Kernel.*(1.0)
  end

  defp compute_percent(_downloaded, _total), do: nil
end
