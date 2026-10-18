defmodule Pinchflat.RateLimit do
  @moduledoc """
  A very small process-independent store for YouTube rate-limit state.

  When any yt-dlp command surfaces an HTTP 429, we "trip" a global cooldown
  during which new yt-dlp invocations wait instead of hammering an IP that
  YouTube has already flagged. State lives in `:persistent_term` so it is
  visible to every process and resets cleanly on app restart.
  """

  require Logger

  @cooldown_key :yt_rate_limit_cooldown_until
  @default_cooldown_minutes 15

  @doc """
  Returns true if a rate-limit cooldown is currently active.

  Returns boolean()
  """
  def tripped?(now \\ DateTime.utc_now()) do
    case :persistent_term.get(@cooldown_key, nil) do
      %DateTime{} = until -> DateTime.compare(now, until) == :lt
      _ -> false
    end
  end

  @doc """
  Trips the rate-limit cooldown for the given number of minutes.

  Returns :ok
  """
  def trip!(minutes \\ @default_cooldown_minutes) do
    until = DateTime.add(DateTime.utc_now(), minutes * 60, :second)
    :persistent_term.put(@cooldown_key, until)

    Logger.warning("YouTube rate limit detected - pausing yt-dlp work until #{until}")

    :ok
  end

  @doc """
  Clears any active cooldown. Mostly useful for tests and manual recovery.

  Returns :ok
  """
  def clear! do
    :persistent_term.put(@cooldown_key, nil)

    :ok
  end

  @doc """
  Seconds remaining in the current cooldown (0 if none).

  Returns non_neg_integer()
  """
  def seconds_remaining(now \\ DateTime.utc_now()) do
    case :persistent_term.get(@cooldown_key, nil) do
      %DateTime{} = until -> max(0, DateTime.diff(until, now))
      _ -> 0
    end
  end
end
