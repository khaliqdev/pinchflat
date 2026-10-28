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
    headers = [
      {"accept", "application/vnd.github+json"},
      {"user-agent", user_agent()}
    ]

    case http_client().get(@latest_release_url, headers, @http_opts) do
      {:ok, body} ->
        parse_tag(body)

      {:error, reason} ->
        {:error, "could not reach GitHub: #{reason}"}
    end
  end

  @doc """
  Compares the installed version against the latest known release. Nil-safe:
  unknown versions or unparseable tags never claim an update.

  Returns :update_available | :up_to_date | :newer_installed | :indeterminate
  """
  def version_state(nil, _latest), do: :indeterminate
  def version_state(_installed, nil), do: :indeterminate

  def version_state(installed, latest) when is_binary(installed) and is_binary(latest) do
    with {:ok, installed_parts} <- parse_version(installed),
         {:ok, latest_parts} <- parse_version(latest) do
      max_parts = max(length(installed_parts), length(latest_parts))
      installed_parts = pad_version(installed_parts, max_parts)
      latest_parts = pad_version(latest_parts, max_parts)

      cond do
        installed_parts < latest_parts -> :update_available
        installed_parts > latest_parts -> :newer_installed
        true -> :up_to_date
      end
    else
      _ -> :indeterminate
    end
  end

  @doc """
  The User-Agent GitHub's REST API requires on every request.

  Returns String.t()
  """
  def user_agent do
    vsn = Application.spec(:pinchflat, :vsn)
    version = if is_list(vsn), do: to_string(vsn), else: "unknown"

    "re-Pinchflat/#{version} (+https://github.com/khaliqdev/pinchflat)"
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

  # yt-dlp tags are date-like ("2026.10.21"; nightlies append a time segment),
  # so comparing the dot-separated parts numerically is exact. Anything else
  # (source builds, empty strings) is unparseable and gets :indeterminate.
  defp parse_version(tag) do
    parts = String.split(String.trim(tag), ".")

    if parts != [] and Enum.all?(parts, &Regex.match?(~r/^\d+$/, &1)) do
      {:ok, Enum.map(parts, &String.to_integer/1)}
    else
      :error
    end
  end

  defp pad_version(parts, max_parts), do: parts ++ List.duplicate(0, max_parts - length(parts))

  defp http_client do
    Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
  end
end
