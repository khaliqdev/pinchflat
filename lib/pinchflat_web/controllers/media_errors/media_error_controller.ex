defmodule PinchflatWeb.MediaErrors.MediaErrorController do
  use PinchflatWeb, :controller

  alias Pinchflat.Media
  alias Pinchflat.Sources

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
