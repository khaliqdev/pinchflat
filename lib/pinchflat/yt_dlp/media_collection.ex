defmodule Pinchflat.YtDlp.MediaCollection do
  @moduledoc """
  Contains utilities for working with collections of
  media (aka: a source [ie: channels, playlists]).
  """

  require Logger

  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  @doc """
  Returns a list of maps representing the media in the collection.
  Optionally takes a list of additional command options to pass to yt-dlp
  or configuration-related options to pass to the runner.

  Runner Options:
    - :file_listener_handler - a function that will be called with the path to the
      file that will be written to when yt-dlp is done. This is useful for
      setting up a file watcher to know when the file is ready to be read.
    - :use_cookies - whether or not to use user-provided cookies when fetching the media details

  Returns {:ok, [map()]} | {:error, any, ...}.
  """
  def get_media_attributes_for_collection(url, command_opts \\ [], addl_opts \\ []) do
    # `ignore_no_formats_error` is necessary because yt-dlp will error out if
    # the first video has not released yet (ie: is a premier). We don't care about
    # available formats since we're just getting the media details
    all_command_opts = [:simulate, :skip_download, :ignore_no_formats_error, :no_warnings] ++ command_opts
    use_cookies = Keyword.get(addl_opts, :use_cookies, false)
    output_template = YtDlpMedia.indexing_output_template()
    output_filepath = FilesystemUtils.generate_metadata_tmpfile(:json)
    file_listener_handler = Keyword.get(addl_opts, :file_listener_handler, false)
    runner_opts = [output_filepath: output_filepath, use_cookies: use_cookies]
    action = :get_media_attributes_for_collection

    if file_listener_handler do
      file_listener_handler.(output_filepath)
    end

    case backend_runner().run(url, action, all_command_opts, output_template, runner_opts) do
      {:ok, output} ->
        parsed_lines =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case Phoenix.json_library().decode(line) do
              {:ok, parsed_json} ->
                YtDlpMedia.response_to_struct(parsed_json)

              _ ->
                nil
            end
          end)

        {:ok, Enum.filter(parsed_lines, &(&1 != nil))}

      err ->
        err
    end
  end

  @doc """
  Gets a source's ID and name from its URL.

  yt-dlp does not _really_ have source-specific functions that return what
  we need, so instead we're fetching just the first video (using playlist_end: 1)
  and parsing the source ID and name from _its_ metadata

  Returns {:ok, map()} | {:error, any, ...}.
  """
  def get_source_details(source_url, command_opts \\ [], addl_opts \\ []) do
    # `ignore_no_formats_error` is necessary because yt-dlp will error out if
    # the first video has not released yet (ie: is a premier). We don't care about
    # available formats since we're just getting the source details
    default_opts = [
      :simulate,
      :skip_download,
      :ignore_no_formats_error,
      playlist_end: 1
    ]

    all_command_opts = default_opts ++ command_opts
    output_template = "%(.{channel,channel_id,playlist_id,playlist_title,filename})j"
    action = :get_source_details

    with {:ok, output} <- backend_runner().run(source_url, action, all_command_opts, output_template, addl_opts),
         {:ok, parsed_json} <- Phoenix.json_library().decode(output) do
      {:ok, format_source_details(parsed_json)}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "Error decoding JSON response"}
      err -> err
    end
  end

  @doc """
  Gets a source's metadata from its URL.

  This is mostly for things like getting the source's avatar and banner image
  (if applicable). However, this yt-dlp call doesn't have enough overlap with
  `get_source_details/1` to allow combining them - this one has _almost_ everything
  we need, but it doesn't contain enough information to tell 100% if the url is a channel
  or a playlist.

  The main purpose of this (past using as a fetcher for _other_ metadata) is to live
  as a compressed blob for possible future use. That's why it's not getting formatted like
  `get_source_details/1`

  ! IMPORTANT ! - you'll always want to set `playlist_items: int` in `addl_opts.
  This is great if you want to also return details about the videos in the playlists,
  but it should be set in all cases to not over-fetch data.
  For channels you should usually set this to 0 since channels return all the
  metadata we need without needing to fetch the videos. On the other hand, playlists
  don't return very useful images so you can set this to 1 to get the first video's
  images, for instance.

  Returns {:ok, map()} | {:error, any, ...}.
  """
  def get_source_metadata(source_url, command_opts, addl_opts \\ []) do
    # This only validates that the `playlist_items` key is present. It's otherwise unused
    _playlist_items = Keyword.fetch!(command_opts, :playlist_items)

    all_command_opts = [:skip_download] ++ command_opts
    output_template = "playlist:%()j"
    action = :get_source_metadata

    with {:ok, output} <- backend_runner().run(source_url, action, all_command_opts, output_template, addl_opts),
         {:ok, parsed_json} <- decode_output(output) do
      {:ok, parsed_json}
    else
      err -> err
    end
  end

  # yt-dlp's --print-to-file APPENDS every template evaluation to the file. For
  # a channel URL one run writes the tab-expanded listing of EVERY tab (videos,
  # shorts, live) PLUS the channel-wrapper playlist (whose entries are the
  # channel's tabs), so the content is multiple whitespace-separated JSON
  # documents and a plain decode fails with "unexpected byte" at the second
  # document. Decode every top-level document and merge the tab-expanded media
  # listings into one: the wrapper's entries are themselves playlists, while
  # the expanded listings' entries are what a source actually indexes.
  defp decode_output(output) do
    case Phoenix.json_library().decode(output) do
      {:ok, json} ->
        {:ok, json}

      {:error, _} ->
        case decodable_documents(output) do
          [] ->
            {:error, %Jason.DecodeError{position: 0, data: output}}

          docs ->
            {:ok, merge_playlist_docs(docs)}
        end
    end
  end

  defp decodable_documents(output) do
    output
    |> top_level_document_ranges()
    |> Enum.flat_map(fn {start, length} ->
      case Phoenix.json_library().decode(binary_part(output, start, length)) do
        {:ok, %{} = doc} -> [doc]
        _ -> []
      end
    end)
  end

  # Of the documents carrying non-empty entries, skip channel wrappers (their
  # entries are themselves playlists) and merge the rest into ONE listing -
  # keeping only the largest tab listing would hide the media that lives in
  # the other tabs (eg: a shorts-only profile scanning to ~0). Entries are
  # deduped by id, and top-level fields come from the largest listing; with
  # no media listing at all, the last decoded document is the best available.
  defp merge_playlist_docs(docs) do
    case Enum.filter(docs, &media_listing?/1) do
      [] ->
        List.last(docs)

      listings ->
        base = Enum.max_by(listings, fn doc -> length(doc["entries"] || []) end)

        base
        |> Map.put("entries", merged_media_entries(listings))
        |> Map.put("playlist_count", combined_playlist_count(listings))
    end
  end

  defp media_listing?(doc) do
    case doc["entries"] do
      [first | _] when is_map(first) -> media_entry?(first)
      _ -> false
    end
  end

  # Media entries are flat video records. Playlist-shaped entries - channel
  # wrappers and tabs - point at other playlists instead: they announce
  # themselves with a "playlist" _type or carry their own "entries"
  defp media_entry?(%{"_type" => "playlist"}), do: false
  defp media_entry?(%{"entries" => _}), do: false
  defp media_entry?(entry) when is_map(entry), do: true
  defp media_entry?(_entry), do: false

  # First occurrence wins - tabs rarely overlap, but one entry per video id
  # mirrors what the source actually indexes
  defp merged_media_entries(listings) do
    listings
    |> Enum.flat_map(fn doc -> doc["entries"] || [] end)
    |> Enum.filter(&media_entry?/1)
    |> Enum.uniq_by(& &1["id"])
  end

  # Each tab's playlist_count is its true listing size (unaffected by the
  # playlist_items range), so the combined size is their sum - falling back
  # to a listing's own media-entry count when it reports none
  defp combined_playlist_count(listings) do
    Enum.reduce(listings, 0, fn doc, total ->
      case doc["playlist_count"] do
        count when is_integer(count) -> total + count
        _ -> total + length(Enum.filter(doc["entries"] || [], &media_entry?/1))
      end
    end)
  end

  defp top_level_document_ranges(output) do
    {ranges, _final_depth} = scan_documents(output, 0, byte_size(output), 0, false, false, nil, [])
    Enum.reverse(ranges)
  end

  defp scan_documents(_output, pos, size, depth, _in_string, _escaped, _doc_start, ranges)
       when pos >= size do
    {ranges, depth}
  end

  defp scan_documents(output, pos, size, depth, in_string, escaped, doc_start, ranges) do
    byte = :binary.at(output, pos)

    # String state AFTER consuming this byte. Escape/backslash handling only
    # applies inside strings; outside, a backslash is an ordinary byte.
    {in_string2, escaped2} =
      cond do
        in_string and escaped -> {true, false}
        in_string and byte == ?\\ -> {true, true}
        in_string and byte == ?" -> {false, false}
        in_string -> {true, false}
        byte == ?" -> {true, false}
        true -> {false, false}
      end

    # Braces inside strings (including the quote bytes themselves) are content,
    # not structure.
    structural? = not in_string and byte != ?"

    {depth2, doc_start2, ranges2} =
      cond do
        not structural? ->
          {depth, doc_start, ranges}

        byte == ?{ and depth == 0 ->
          {1, pos, ranges}

        byte == ?{ ->
          {depth + 1, doc_start, ranges}

        byte == ?} and depth == 1 ->
          {0, nil, [{doc_start, pos - doc_start + 1} | ranges]}

        byte == ?} ->
          {depth - 1, doc_start, ranges}

        true ->
          {depth, doc_start, ranges}
      end

    scan_documents(output, pos + 1, size, depth2, in_string2, escaped2, doc_start2, ranges2)
  end

  defp format_source_details(response) do
    # NOTE: I should probably make this a struct some day
    %{
      channel_id: response["channel_id"],
      channel_name: response["channel"],
      playlist_id: response["playlist_id"],
      playlist_name: response["playlist_title"],
      # It's not a name, it's a path dammit!
      # This actually isn't used for the inital response - it's
      # used later to update a source's metadata
      filepath: response["filename"]
    }
  end

  defp backend_runner do
    # This approach lets us mock the command for testing
    Application.get_env(:pinchflat, :yt_dlp_runner)
  end
end
