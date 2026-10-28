defmodule PinchflatWeb.Pages.PageHTML do
  use PinchflatWeb, :html

  alias Pinchflat.Utils.DisplayTime

  embed_templates "page_html/*"

  @doc """
  Relative age for dashboard tiles: today, Nd ago, or the ISO date past a
  week. Nil-safe for legacy items without a timestamp. Both sides go through
  DisplayTime so the comparison is local-date vs local-date, not local vs UTC.
  """
  def days_ago(datetime, now \\ DateTime.utc_now())

  def days_ago(nil, _now), do: "unknown"

  def days_ago(datetime, now) do
    date = DisplayTime.date_to_local(datetime)
    today = DisplayTime.date_to_local(now)
    days = Date.diff(today, date)

    cond do
      days <= 0 -> "today"
      days == 1 -> "yesterday"
      days < 7 -> "#{days}d ago"
      true -> Date.to_iso8601(date)
    end
  end

  @doc """
  Seconds -> "H:MM:SS" (or "M:SS") for the poster duration badge. Nil-safe.
  """
  def format_duration(nil), do: ""

  def format_duration(seconds) when is_integer(seconds) and seconds > 0 do
    h = div(seconds, 3600)
    m = rem(seconds, 3600) |> div(60)
    s = rem(seconds, 60)

    if h > 0 do
      :io_lib.format("~B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
    else
      :io_lib.format("~B:~2..0B", [m, s]) |> IO.iodata_to_binary()
    end
  end

  def format_duration(_), do: ""
end
