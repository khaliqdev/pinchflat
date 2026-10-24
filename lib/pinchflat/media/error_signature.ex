defmodule Pinchflat.Media.ErrorSignature do
  @moduledoc """
  Normalizes errors for presentation without changing stored error text.
  """

  @max_groups 20
  @max_label_length 180

  def normalize(last_error, media_id \\ nil)

  def normalize(nil, _media_id), do: missing_details()

  def normalize(last_error, media_id) when is_binary(last_error) do
    lines =
      last_error
      |> String.replace(~r/\e\[[0-9;]*m/, "")
      |> String.split(~r/\r\n|\r|\n/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    diagnostic =
      Enum.find_value(lines, fn line ->
        case Regex.run(~r/\b(?:ERROR|WARNING):.*$/i, line) do
          [match] -> match
          nil -> nil
        end
      end) || List.first(lines)

    case diagnostic do
      nil ->
        missing_details()

      line ->
        normalized =
          line
          |> replace_known_media_id(media_id)
          |> String.replace(
            ~r/(\[youtube(?::[^\]]+)?\]\s+)[A-Za-z0-9_-]{11}(\s*:)/i,
            "\\1<video-id>\\2"
          )
          |> String.replace(~r{https?://[^\s<>"']+}i, "<url>")
          |> String.replace(
            ~r/\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)?\b/,
            "<timestamp>"
          )
          |> String.replace(
            ~r/\b\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\b/,
            "<timestamp>"
          )
          |> String.replace(
            ~r/\bHTTP(?:\s+Error)?[\s:]+([1-5]\d{2})\b/i,
            "HTTP-\\1"
          )
          |> String.replace(
            ~r/(?<![A-Za-z0-9_-])\d+(?:[.,]\d+)*(?![A-Za-z0-9_-])/,
            "<n>"
          )
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        %{
          signature: "line:" <> String.downcase(normalized),
          label: String.slice(normalized, 0, @max_label_length)
        }
    end
  end

  def group(items) when is_list(items) do
    ordered =
      items
      |> Enum.reduce(%{}, fn item, groups ->
        %{signature: signature, label: label} =
          normalize(item.last_error, item.media_id)

        initial = %{
          signature: signature,
          label: label,
          count: 1,
          items: [item]
        }

        Map.update(groups, signature, initial, fn group ->
          %{group | count: group.count + 1, items: [item | group.items]}
        end)
      end)
      |> Map.values()
      |> Enum.map(fn group ->
        %{group | items: Enum.reverse(group.items)}
      end)
      |> Enum.sort_by(fn group -> {-group.count, group.signature} end)

    bounded =
      if length(ordered) > @max_groups do
        {main_groups, overflow_groups} =
          Enum.split(ordered, @max_groups - 1)

        positions =
          items
          |> Enum.with_index()
          |> Map.new(fn {item, index} -> {item.id, index} end)

        overflow_items =
          overflow_groups
          |> Enum.flat_map(& &1.items)
          |> Enum.sort_by(&Map.fetch!(positions, &1.id))

        overflow = %{
          signature: "overflow",
          label: "Other signatures (#{length(overflow_groups)} groups)",
          count: length(overflow_items),
          items: overflow_items
        }

        main_groups ++ [overflow]
      else
        ordered
      end

    bounded
    |> Enum.with_index(1)
    |> Enum.map(fn {group, index} ->
      Map.put(group, :id, "error-group-#{index}")
    end)
  end

  defp replace_known_media_id(text, media_id) when is_binary(media_id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{11}\z/, media_id) do
      String.replace(text, media_id, "<video-id>")
    else
      text
    end
  end

  defp replace_known_media_id(text, _media_id), do: text

  defp missing_details do
    %{
      signature: "missing",
      label: "No error details recorded"
    }
  end
end
