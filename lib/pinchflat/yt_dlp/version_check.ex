defmodule Pinchflat.YtDlp.VersionCheck do
  @moduledoc """
  Checks the latest stable yt-dlp release from GitHub without touching the
  installed binary. Powers the App Info updater card's "update available"
  badge and the "Check for updates" button.

  Deliberately pinned to the stable channel: the shipped image installs the
  stable release, and a channel mismatch would make the badge lie. One
  unauthenticated request per check stays far inside GitHub's rate limits.
  """

  @latest_release_url "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
  @http_opts [body_format: :binary]

  @doc """
  Fetches the latest stable release version tag (e.g. "2026.10.21").

  Returns {:ok, String.t()} | {:error, String.t()}
  """
  def latest_stable_version do
    case http_client().get(@latest_release_url, [{"accept", "application/vnd.github+json"}], @http_opts) do
      {:ok, body} ->
        parse_tag(body)

      {:error, reason} ->
        {:error, "could not reach GitHub: #{reason}"}
    end
  end

  @doc """
  True when the installed version differs from the latest known release.
  Nil-safe: unknown versions or a failed check never claim an update.

  Returns boolean()
  """
  def update_available?(nil, _latest), do: false
  def update_available?(_installed, nil), do: false

  def update_available?(installed, latest) when is_binary(installed) and is_binary(latest) do
    String.trim(installed) != String.trim(latest)
  end

  defp parse_tag(body) do
    with {:ok, %{"tag_name" => tag}} when is_binary(tag) <- Phoenix.json_library().decode(body),
         trimmed <- String.trim(tag),
         false <- trimmed == "" do
      {:ok, trimmed}
    else
      _ -> {:error, "unexpected response from GitHub"}
    end
  end

  defp http_client do
    Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
  end
end
