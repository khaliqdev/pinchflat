defmodule Pinchflat.Lifecycle.Notifications.FailureDigestWorker do
  @moduledoc """
  Periodically sends ONE bundled apprise notification covering all new download
  failures since the last run, when the `failure_notifications` setting is on.

  A digest (rather than notifying inline from the download path) means one
  mass-failure event - eg. cookie expiry failing every queued item - produces
  a single notification instead of dozens, and covers every failure path
  including future workers.

  Scheduled every 15 minutes via the Oban Cron plugin. Returns :ok
  """

  use Oban.Worker,
    queue: :local_data,
    tags: ["local_data"],
    max_attempts: 1

  require Logger

  alias Pinchflat.Lifecycle.Notifications.CommandRunner, as: AppriseRunner
  alias Pinchflat.Media
  alias Pinchflat.Settings

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Settings.get!(:failure_notifications) do
      run_digest()
    else
      :ok
    end
  end

  defp run_digest do
    through =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(-1, :second)

    with {:ok, since} <- digest_cursor(through) do
      if DateTime.compare(since, through) == :lt do
        case Media.failure_digest_window(since, through) do
          %{count: 0} ->
            persist_cursor(through)

          %{count: count, items: items} ->
            with :ok <- send_digest(items, count) do
              persist_cursor(through)
            end
        end
      else
        :ok
      end
    end
  end

  # Persisting the initial lower bound is initialization, not acknowledgement
  # of delivery - it stops an uninitialized cursor from sliding forward while
  # nothing has been acknowledged at all yet.
  defp digest_cursor(through) do
    case Settings.get(:failure_digest_cursor) do
      {:ok, %DateTime{} = cursor} ->
        {:ok, cursor}

      _ ->
        initial = DateTime.add(through, -15 * 60, :second)

        case Settings.set(failure_digest_cursor: initial) do
          {:ok, _} -> {:ok, initial}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp persist_cursor(through) do
    case Settings.set(failure_digest_cursor: through) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_digest(items, count) do
    first = hd(items)
    first_error = first.last_error |> to_string() |> String.split("\n") |> hd() |> String.slice(0, 140)

    opts = [
      title: "[re:Pinchflat] Download failures",
      body: "#{count} new download failure(s). First: #{first.title} - #{first_error}"
    ]

    case apprise_runner().run(Settings.get!(:apprise_server), opts) do
      {:ok, _} ->
        Logger.info("Sent failure digest notification covering #{count} item(s)")
        :ok

      {:error, :no_servers} ->
        Logger.warning("Failure digest enabled but no Apprise server is configured")
        {:error, :no_servers}

      {:error, err} ->
        Logger.error("Failed to send failure digest notification: #{inspect(err)}")
        {:error, err}
    end
  end

  defp apprise_runner do
    Application.get_env(:pinchflat, :apprise_runner, AppriseRunner)
  end

end
