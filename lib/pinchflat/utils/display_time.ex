defmodule Pinchflat.Utils.DisplayTime do
  @moduledoc """
  Converts stored timestamps for display without changing stored values.

  NaiveDateTime inputs are interpreted as UTC. Date values are already
  calendar dates and are not shifted.
  """

  @utc_zone "Etc/UTC"

  def to_local(
        datetime,
        timezone \\ Application.get_env(:pinchflat, :display_timezone, "UTC")
      )

  def to_local(nil, _timezone), do: nil

  def to_local(%NaiveDateTime{} = datetime, timezone) do
    datetime
    |> DateTime.from_naive!(@utc_zone)
    |> to_local(timezone)
  end

  def to_local(%DateTime{} = datetime, timezone) do
    zone = normalize_timezone(timezone)

    case DateTime.shift_zone(datetime, zone, Tzdata.TimeZoneDatabase) do
      {:ok, local_datetime} ->
        local_datetime

      {:error, _reason} ->
        to_utc(datetime)
    end
  rescue
    ArgumentError ->
      to_utc(datetime)
  end

  def date_to_local(nil), do: nil
  def date_to_local(%Date{} = date), do: date

  def date_to_local(datetime) do
    datetime
    |> to_local()
    |> DateTime.to_date()
  end

  defp normalize_timezone(timezone) when is_binary(timezone) do
    case String.trim(timezone) do
      "" -> @utc_zone
      zone -> zone
    end
  end

  defp normalize_timezone(_timezone), do: @utc_zone

  defp to_utc(datetime) do
    DateTime.shift_zone!(
      datetime,
      @utc_zone,
      Calendar.UTCOnlyTimeZoneDatabase
    )
  end
end
