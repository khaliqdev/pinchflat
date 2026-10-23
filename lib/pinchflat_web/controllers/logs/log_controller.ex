defmodule PinchflatWeb.Logs.LogController do
  use PinchflatWeb, :controller

  alias Pinchflat.Logs.LogBuffer
  alias Pinchflat.Utils.NumberUtils

  def index(conn, _params) do
    render(conn, :index, page_title: "Logs")
  end

  @doc """
  Exports the last N buffered lines as a text file for bug reports - the
  in-app twin of /download_logs (which serves the rotating file on disk).
  """
  def download(conn, params) do
    lines =
      params["lines"]
      |> parse_lines()
      |> LogBuffer.recent()
      |> Enum.map_join("\n", & &1.line)

    send_download(conn, {:binary, lines <> "\n"},
      filename: "pinchflat-in-app-logs-#{Date.utc_today()}.txt",
      content_type: "text/plain"
    )
  end

  defp parse_lines(nil), do: 1_000

  defp parse_lines(lines) when is_binary(lines) do
    case Integer.parse(lines) do
      {count, _} -> NumberUtils.clamp(count, 1, 100_000)
      :error -> 1_000
    end
  end

  defp parse_lines(_), do: 1_000
end
