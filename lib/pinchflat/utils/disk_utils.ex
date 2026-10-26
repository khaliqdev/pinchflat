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

  @doc """
  Returns free and total bytes for the filesystem containing the given path,
  or nil if it can't be determined. Powers the dashboard's free-space gauge.
  """
  def volume_stats(path) do
    case System.cmd("df", ["-P", "-B1", path], stderr_to_stdout: true) do
      {output, 0} ->
        parse_volume_stats(output)

      {output, _} ->
        Logger.warning("Unable to read volume stats for #{path}: #{String.trim(output)}")

        nil
    end
  rescue
    e ->
      Logger.warning("Unable to read volume stats for #{path}: #{Exception.message(e)}")

      nil
  end

  defp parse_volume_stats(output) do
    fields =
      output
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
      |> List.last()
      |> String.split()

    with [_, total, _used, avail | _] <- fields,
         total when is_integer(total) <- parse_int(total),
         free when is_integer(free) <- parse_int(avail) do
      %{total_bytes: total, free_bytes: free}
    else
      _ -> nil
    end
  end

  defp parse_int(string) do
    case Integer.parse(string) do
      {n, _} -> n
      :error -> nil
    end
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
