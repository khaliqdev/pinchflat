defmodule Pinchflat.Utils.DiskUtils do
  @moduledoc """
  Disk utility methods. Reads free space for a path via the system `df`
  (POSIX format so paths never wrap).
  """

  require Logger

  @doc """
  Returns free bytes available at the given path, or nil if it can't be
  determined (missing path, no `df`, unexpected output).

  Returns non_neg_integer() | nil
  """
  def free_bytes(path) do
    case System.cmd("df", ["-P", "-B1", path], stderr_to_stdout: true) do
      {output, 0} ->
        parse_free_bytes(output)

      {output, _} ->
        Logger.warning("Unable to read free space for #{path}: #{String.trim(output)}")

        nil
    end
  rescue
    e ->
      Logger.warning("Unable to read free space for #{path}: #{Exception.message(e)}")

      nil
  end

  defp parse_free_bytes(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> String.split()
    |> Enum.at(3)
    |> case do
      nil -> nil
      avail -> Integer.parse(avail) |> elem(0)
    end
  rescue
    _ -> nil
  end
end
