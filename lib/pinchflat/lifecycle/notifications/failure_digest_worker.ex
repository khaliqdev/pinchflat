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
    tags: ["local_data"]

  require Logger

  alias Pinchflat.Lifecycle.Notifications.CommandRunner, as: AppriseRunner
  alias Pinchflat.Media
  alias Pinchflat.Settings

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Settings.get!(:failure_notifications) do
      run_digest()
    end

    :ok
  end

  defp run_digest do
    since =
      case Settings.get(:failure_digest_cursor) do
        {:ok, %DateTime{} = cursor} -> cursor
        _ -> DateTime.add(DateTime.utc_now(), -15 * 60, :second)
      end

    items = Media.list_errored_media_items(since: since, limit: 100)

    case items do
      [] ->
        :ok

      items ->
        send_digest(items)
        advance_cursor(items)
    end
  end

  defp send_digest(items) do
    first = hd(items)
    first_error = first.last_error |> to_string() |> String.split("\n") |> hd() |> String.slice(0, 140)

    # A full page (limit 100) means more items are waiting behind the cursor;
    # say so rather than undercounting a mass failure
    count_label = if length(items) >= 100, do: "100+", else: Integer.to_string(length(items))

    opts = [
      title: "[re:Pinchflat] Download failures",
      body: "#{count_label} new download failure(s). First: #{first.title} - #{first_error}"
    ]

    case apprise_runner().run(Settings.get!(:apprise_server), opts) do
      {:ok, _} ->
        Logger.info("Sent failure digest notification covering #{length(items)} item(s)")

      {:error, :no_servers} ->
        Logger.warning("Failure digest enabled but no Apprise server is configured")

      {:error, err} ->
        Logger.error("Failed to send failure digest notification: #{inspect(err)}")
    end
  end

  defp apprise_runner do
    Application.get_env(:pinchflat, :apprise_runner, AppriseRunner)
  end

  defp advance_cursor(items) do
    latest = items |> Enum.map(& &1.updated_at) |> Enum.max()
    Settings.set(failure_digest_cursor: latest)
  end
end
