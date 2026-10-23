defmodule Pinchflat.Sources.SourceScanner do
  @moduledoc """
  Estimates how many media items a source URL would download, based on the
  source form's current settings, before the source is saved (ROADMAP 4.1).

  Makes one flat yt-dlp listing call per scan via
  `YtDlp.MediaCollection.get_source_metadata/3`, which runs through
  `CommandRunner` - so scans inherit the user's cookies (opted in per the
  source's cookie behaviour, as an indexing operation) and the global 429
  RateLimit cooldown. A scan is real YouTube traffic.

  NOTE: the ROADMAP sketch says `playlist_items: 0`, but that returns the
  playlist blob with EMPTY entries (see
  test/support/files/channel_source_metadata.json) - enough for a total, but
  not for the per-entry breakdown the feature is built around. So the scan
  asks for a flat extraction of a bounded range of entries instead:
  `--flat-playlist` keeps the call to ~1 listing request per 100 videos (no
  per-video fetches) and the `playlist_items` range caps how many entries get
  parsed into memory. `playlist_count` still reports the true listing size.

  The count math mirrors the real download-eligibility predicate
  (`MediaQuery.pending/0`) as far as it can be applied cheaply, in order:
  download cutoff date, title filter regex, shorts/livestream behaviours
  (same duration + live-status heuristics the indexer uses), min/max
  duration, then the optional download-count cap. Description regex and
  members-only visibility CANNOT be applied cheaply - they need per-video
  metadata, which is what the first index fetches - so the output is an
  estimate and the UI says so. Missing per-entry data (no title, duration,
  or upload date) counts as included, except that a set title filter drops
  titleless entries exactly like the real SQL does.
  """

  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.YtDlp.Media, as: YtDlpMedia
  alias Pinchflat.YtDlp.MediaCollection

  # v1 uses a hard timeout and a "channel too large for preview" message -
  # a scan blocks the request process for the whole listing (and for any
  # active 429 cooldown sleep). Follow-up: move the scan into an Oban job
  # with a "scan running..." indicator for huge channels.
  @default_timeout_ms 90_000

  # Flat-extraction range. The cap keeps a 100k-entry channel from ballooning
  # the output file and our memory use; `playlist_count` still reports the
  # true total, and `analyzed_entries` tells the UI what the math ran on.
  @playlist_item_range "1-10000"

  # The scan form doesn't carry these, but the `:initial` validation stage
  # requires them (see Source.changeset/3).
  @scan_defaults %{
    "enabled" => "true",
    "index_frequency_minutes" => "60",
    "fast_index" => "false",
    "download_media" => "true"
  }

  @doc """
  Runs a preview scan against source-form params (the `source[key]` map from
  the source form) without saving anything. Runs the same validations the real
  save path runs at its cheap stage, so an invalid URL or regex fails before
  any yt-dlp traffic happens.

  Returns:
    - {:ok, %{total_found: integer(), analyzed_entries: integer(),
              estimated_downloads: integer(), breakdown: [%{label: binary(), removed: integer()}]}}
    - {:error, {:invalid, %{field => [message, ...]}}}
    - {:error, :timeout}
    - {:error, {:scan_failed, message}}
  """
  def scan_from_params(source_params, opts \\ []) do
    attrs =
      source_params
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
      |> then(&Map.merge(@scan_defaults, &1))

    changeset = Sources.change_source(%Source{}, attrs, :initial)

    if changeset.valid? do
      scan(Ecto.Changeset.apply_changes(changeset), opts)
    else
      {:error, {:invalid, changeset_errors(changeset)}}
    end
  end

  @doc """
  Runs the scan for a source (saved or built). Preloads the media profile the
  count math needs.

  Options:
    - :timeout_ms - hard timeout for the listing call (default: `timeout_ms/0`)
    - :download_count - optional cap, applied as the last count-math step

  Returns {:ok, map()} | {:error, {:invalid, map()}} | {:error, :timeout} |
          {:error, {:scan_failed, binary()}}
  """
  def scan(%Source{} = source, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms) || timeout_ms()
    source = Repo.preload(source, :media_profile)

    with {:ok, media_profile} <- require_media_profile(source),
         {:ok, title_regex} <- compile_title_regex(source.title_filter_regex) do
      case fetch_source_metadata(source, timeout_ms) do
        {:ok, metadata} ->
          {:ok, count_potential_downloads(metadata, source, media_profile, title_regex, opts)}

        {:error, %Jason.DecodeError{}} ->
          {:error, {:scan_failed, "could not parse yt-dlp output"}}

        {:error, output, _status} ->
          {:error, {:scan_failed, yt_dlp_error_excerpt(output)}}

        # :timeout from the hard timeout, or {:scan_failed, ...} from a crash -
        # pass through unchanged for the controller to shape
        error = {:error, _reason} ->
          error
      end
    end
  end

  @doc """
  The scan's hard timeout in milliseconds. Overridable via the
  `:source_scan_timeout_ms` application env (used by tests).

  Returns non_neg_integer()
  """
  def timeout_ms do
    # `||` (not get_env/3's default) because a test cleanup can STORE nil,
    # and get_env/3 returns a stored nil instead of the default - which would
    # send nil into Task.yield/2 and raise FunctionClauseError
    Application.get_env(:pinchflat, :source_scan_timeout_ms) || @default_timeout_ms
  end

  # One listing call. The Task + `Task.yield/2` is the v1 hard timeout: on
  # expiry the task is killed and the caller gets :timeout. Runs through
  # CommandRunner via MediaCollection, so the scan opts into cookies the same
  # way an indexing operation would and inherits the global 429 cooldown
  # sleep - under an active cooldown a scan blocks for the remaining time,
  # which this same timeout path absorbs.
  defp fetch_source_metadata(source, timeout_ms) do
    command_opts = [:flat_playlist, playlist_items: @playlist_item_range]
    addl_opts = [use_cookies: Sources.use_cookies?(source, :indexing)]

    task =
      Task.async(fn ->
        MediaCollection.get_source_metadata(source.original_url, command_opts, addl_opts)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:scan_failed, "scan crashed: #{inspect(reason)}"}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp require_media_profile(%Source{media_profile: %MediaProfile{}} = source), do: {:ok, source.media_profile}
  defp require_media_profile(_source), do: {:error, {:invalid, %{media_profile_id: ["does not exist"]}}}

  defp count_potential_downloads(metadata, source, media_profile, title_regex, opts) do
    entries = Map.get(metadata, "entries") || []
    playlist_total = Map.get(metadata, "playlist_count")
    total_found = if is_integer(playlist_total), do: playlist_total, else: length(entries)
    cap = Keyword.get(opts, :download_count)

    {survivors, steps} =
      {Enum.map(entries, &normalize_entry/1), []}
      |> run_step("download cutoff date", &passes_cutoff?(&1, source.download_cutoff_date))
      |> run_step("title filter regex", &passes_title_filter?(&1, title_regex))
      |> run_profile_preference_step(media_profile)
      |> run_step("min/max duration", &passes_duration_limits?(&1, source))
      |> run_cap_step(cap)

    # With no per-entry data (eg: a channel blob that came back entryless),
    # the filters are unknown and the honest estimate is the listing total.
    would_download =
      cond do
        entries == [] && cap -> min(total_found, cap)
        entries == [] -> total_found
        true -> length(survivors)
      end

    steps =
      if source.download_media do
        steps
      else
        steps ++ [%{label: "downloads disabled", removed: would_download}]
      end

    %{
      total_found: total_found,
      analyzed_entries: length(entries),
      estimated_downloads: if(source.download_media, do: would_download, else: 0),
      breakdown: steps
    }
  end

  # Each step reports how many entries it removed so the UI can render the
  # breakdown ("-112 by title filter, -230 shorts...").
  defp run_step({entries, steps}, label, predicate) do
    kept = Enum.filter(entries, predicate)
    removed = length(entries) - length(kept)

    {kept, steps ++ [%{label: label, removed: removed}]}
  end

  # Applies the shorts/livestream CASE logic from
  # MediaQuery.format_matching_profile_preference (media_query.ex:58-80). The
  # two behaviours interact (:only + :only is a union, not an intersection),
  # so this runs as one filter but reports separate breakdown steps - a
  # doubly-removed entry is attributed to the shorts step.
  defp run_profile_preference_step({entries, steps}, media_profile) do
    kept = filter_by_profile_preference(entries, media_profile)
    removed = length(entries) - length(kept)

    shorts_removed = if media_profile.shorts_behaviour == :include, do: 0, else: removed
    livestreams_removed = removed - shorts_removed

    steps =
      steps ++
        [
          %{label: "shorts", removed: shorts_removed},
          %{label: "livestreams", removed: livestreams_removed}
        ]

    {kept, steps}
  end

  defp filter_by_profile_preference(entries, media_profile) do
    case {media_profile.shorts_behaviour, media_profile.livestream_behaviour} do
      {:only, :only} -> Enum.filter(entries, &(&1.livestream || &1.short_form_content))
      {:only, _} -> Enum.filter(entries, & &1.short_form_content)
      {_, :only} -> Enum.filter(entries, & &1.livestream)
      {:exclude, :exclude} -> Enum.reject(entries, &(&1.livestream || &1.short_form_content))
      {:exclude, _} -> Enum.reject(entries, & &1.short_form_content)
      {_, :exclude} -> Enum.reject(entries, & &1.livestream)
      _ -> entries
    end
  end

  # The ROADMAP's count math ends in a download-count cap. No persisted
  # `download_count` setting exists yet, so the cap arrives as an option and
  # the step is omitted from the breakdown when unset.
  defp run_cap_step({entries, steps}, nil), do: {entries, steps}

  defp run_cap_step({entries, steps}, cap) when is_integer(cap) do
    kept = Enum.take(entries, cap)

    {kept, steps ++ [%{label: "download count cap", removed: length(entries) - length(kept)}]}
  end

  # Flat entries are shaped like the indexer's per-video payloads, so the same
  # classification heuristics apply. Flat entries can carry the link as `url`
  # instead of `original_url`, and the shorts heuristic keys off it.
  defp normalize_entry(entry) do
    entry
    |> Map.put("original_url", entry["original_url"] || entry["url"])
    |> YtDlpMedia.response_to_struct()
  end

  # Mirror of MediaQuery.upload_date_after_source_cutoff
  # (date(uploaded_at) >= cutoff). Entries without an upload date count as
  # included - the estimate errs high and the real index resolves them.
  defp passes_cutoff?(_entry, nil), do: true

  defp passes_cutoff?(entry, %Date{} = cutoff) do
    case entry.uploaded_at do
      nil -> true
      uploaded_at -> Date.compare(DateTime.to_date(uploaded_at), cutoff) != :lt
    end
  end

  # Mirror of MediaQuery.matches_source_title_regex: no regex matches
  # everything; with a regex, regexp_like(NULL, ...) is not true, so
  # titleless entries drop.
  defp passes_title_filter?(_entry, nil), do: true

  defp passes_title_filter?(entry, title_regex) do
    is_binary(entry.title) && Regex.match?(title_regex, entry.title)
  end

  # Mirror of MediaQuery.meets_min_and_max_duration: a NULL duration fails a
  # set bound, exactly like the SQL comparison would.
  defp passes_duration_limits?(entry, source) do
    duration = entry.duration_seconds

    (is_nil(source.min_duration_seconds) or passes_bound?(duration, source.min_duration_seconds, :min)) and
      (is_nil(source.max_duration_seconds) or passes_bound?(duration, source.max_duration_seconds, :max))
  end

  defp passes_bound?(duration, bound, :min) when is_integer(duration), do: duration >= bound
  defp passes_bound?(duration, bound, :max) when is_integer(duration), do: duration <= bound
  defp passes_bound?(_duration, _bound, _kind), do: false

  # The changeset already validated the regex against SQLite's regexp_like;
  # this second compile guards against the (rare) case where Elixir's PCRE2
  # engine rejects what SQLite accepted.
  defp compile_title_regex(regex) when is_binary(regex) do
    case Regex.compile(regex) do
      {:ok, compiled} -> {:ok, compiled}
      _ -> {:error, {:invalid, %{title_filter_regex: ["is invalid"]}}}
    end
  end

  defp compile_title_regex(_), do: {:ok, nil}

  # yt-dlp puts the actionable ERROR line last; keep a bounded excerpt for the UI
  defp yt_dlp_error_excerpt(output) do
    output
    |> to_string()
    |> String.split("\n", trim: true)
    |> List.last("")
    |> String.slice(0, 300)
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
