defmodule PinchflatWeb.MediaErrors.MediaErrorController do
  use PinchflatWeb, :controller

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Media
  alias Pinchflat.Sources

  def retry(conn, _params) do
    errored_items = Media.list_errored_media_items(limit: 100)
    # Only retry items the worker would actually act on: clearing errors on
    # ignored items would un-ignore them, and clearing errors on already-downloaded
    # items would silently hide real breakage. One batched query instead of
    # per-item pending checks (~3 queries each).
    retryable_ids = Media.pending_download_ids_for(Enum.map(errored_items, & &1.id))
    {retryable, skipped} = Enum.split_with(errored_items, &(&1.id in retryable_ids))

    Enum.each(retryable, fn item ->
      Media.update_media_item(item, %{last_error: nil})
      MediaDownloadWorker.kickoff_with_task(item)
    end)

    conn
    |> put_flash(:info, "Retried #{length(retryable)} item(s) (skipped #{length(skipped)} ignored or already downloaded)")
    |> redirect(to: ~p"/errors")
  end

  def index(conn, params) do
    source_id = parse_source_id(params["source_id"])

    render(conn, :index,
      errors: Media.list_errored_media_items(source_id: source_id),
      sources: Sources.list_sources(),
      source_id: source_id,
      page_title: "Errors"
    )
  end

  defp parse_source_id(nil), do: nil

  defp parse_source_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> int
      :error -> nil
    end
  end
end
