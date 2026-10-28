defmodule Pinchflat.HTTP.HTTPClient do
  @moduledoc """
  This module provides a simple interface for making HTTP requests.

  Made to be easily swappable with other HTTP clients. If you need more complexity
  or security, check out HTTPoison or Mint.
  """

  alias Pinchflat.HTTP.HTTPBehaviour

  @behaviour HTTPBehaviour

  @doc """
  Makes a GET request to the given URL and returns the response.

  NOTE: I can't really test this with Mox and I can't think of a way to test this
  that isn't ultimately redundant. I'm just going to leave it untested for now and
  focus more on testing the consumers of this module (the format_error/1 helper
  below is unit-tested directly).

  Returns {:ok, String.t()} | {:error, String.t()}
  """
  @impl HTTPBehaviour
  def get(url, headers \\ [], opts \\ []) do
    headers = parse_headers(headers)

    # Without explicit timeouts a blackholed connection blocks the calling
    # worker slot forever (the :httpc default is infinity)
    http_opts = [timeout: 30_000, connect_timeout: 10_000]

    case :httpc.request(:get, {url, headers}, http_opts, opts) do
      {:ok, {{_version, 200, _reason_phrase}, _headers, body}} ->
        {:ok, to_string(body)}

      {:ok, {{_version, status_code, reason_phrase}, _headers, _body}} ->
        {:error, "HTTP request failed with status code #{status_code}: #{reason_phrase}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{format_error(reason)}"}
    end
  end

  @doc """
  Formats an :httpc error reason into a string without ever raising. :httpc reasons
  are often tuples (e.g. `{:failed_connect, [...]}`) which can't be interpolated
  directly, so they're inspected and clamped to a sane length.

  Returns String.t()
  """
  def format_error(reason) do
    reason
    |> Kernel.inspect(limit: 50)
    |> String.slice(0, 500)
  end

  defp parse_headers(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end
end
