defmodule PinchflatWeb.Api.V1Controller do
  use PinchflatWeb, :controller

  alias Pinchflat.Media
  alias Pinchflat.Utils.NumberUtils
  alias Pinchflat.Sources

  @max_limit 500

  def sources(conn, _params) do
    sources = Sources.list_sources()
    counts = Media.downloaded_counts_by_source()

    json(conn, %{
      data: Enum.map(sources, fn source -> render_source(source, counts) end)
    })
  end

  def source_media(conn, %{"id" => id} = params) do
    with {int_id, ""} <- Integer.parse(to_string(id)),
         {:ok, _source} <- wrap_get(fn -> Sources.get_source!(int_id) end) do
      media_items = Media.list_media_items_for_api(nil, api_opts(params, int_id))

      json(conn, %{data: Enum.map(media_items, &render_media_item/1)})
    else
      _ -> send_not_found(conn)
    end
  end

  def media_items(conn, params) do
    media_items = Media.list_media_items_for_api(params["state"], api_opts(params, nil))

    json(conn, %{data: Enum.map(media_items, &render_media_item/1)})
  end

  def media_item(conn, %{"id" => id}) do
    with {int_id, ""} <- Integer.parse(to_string(id)),
         {:ok, media_item} <- wrap_get(fn -> Media.get_media_item!(int_id) end) do
      json(conn, %{data: render_media_item(media_item)})
    else
      _ -> send_not_found(conn)
    end
  end

  defp wrap_get(fun) do
    {:ok, fun.()}
  rescue
    Ecto.NoResultsError -> :error
  end

  defp api_opts(params, source_id) do
    [
      # SQLite treats a negative LIMIT as "no bound", which would let
      # ?limit=-1 dump the whole table in one response. Nonsense values
      # degrade to a single-item page rather than empty
      limit: parse_int(params["limit"], 100) |> NumberUtils.clamp(1, @max_limit),
      offset: max(parse_int(params["offset"], 0), 0),
      source_id: source_id
    ]
  end

  defp send_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end

  defp parse_int(nil, default), do: default

  # Plug parses repeated params as lists ("?limit=1&limit=2") - coerce to
  # string so Integer.parse can't raise on them
  defp parse_int(value, default) when is_list(value), do: parse_int(List.first(value), default)

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> default
    end
  end

  # Whitelisted fields only - internal filepaths and bookkeeping columns stay out
  # of the API surface so it stays stable as the schema evolves
  defp render_media_item(item) do
    %{
      id: item.id,
      uuid: item.uuid,
      source_id: item.source_id,
      title: item.title,
      media_id: item.media_id,
      original_url: item.original_url,
      uploaded_at: item.uploaded_at,
      downloaded_at: item.media_downloaded_at,
      duration_seconds: item.duration_seconds,
      media_size_bytes: item.media_size_bytes,
      state: media_item_state(item),
      livestream: item.livestream,
      members_only: item.members_only,
      short_form_content: item.short_form_content,
      prevented: item.prevent_download,
      last_error: item.last_error
    }
  end

  defp media_item_state(item) do
    cond do
      item.prevent_download -> :ignored
      is_binary(item.media_filepath) -> :downloaded
      is_binary(item.last_error) -> :errored
      true -> :pending
    end
  end

  defp render_source(source, counts) do
    %{
      id: source.id,
      uuid: source.uuid,
      custom_name: source.custom_name,
      collection_name: source.collection_name,
      collection_type: source.collection_type,
      original_url: source.original_url,
      enabled: source.enabled,
      download_media: source.download_media,
      fast_index: source.fast_index,
      cookie_behaviour: source.cookie_behaviour,
      last_indexed_at: source.last_indexed_at,
      downloaded_count: Map.get(counts, source.id, 0)
    }
  end
end
