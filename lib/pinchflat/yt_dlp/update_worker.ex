defmodule Pinchflat.YtDlp.UpdateWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    tags: ["local_data"],
    # A failed update isn't transient in a useful way - the nightly schedule
    # will try again tomorrow, so don't pile up retries of a dead binary swap
    max_attempts: 1

  require Logger

  alias __MODULE__
  alias Pinchflat.Settings

  @doc """
  Starts the yt-dlp update worker. Does not attach it to a task like `kickoff_with_task/2`.

  Options:
    - `:manual` - when true the update runs regardless of the auto-update mode.
      For explicit user actions (the App Info "Update now" button); the
      YT_DLP_AUTO_UPDATE gate only governs the automatic cron/boot runs.

  Returns {:ok, %Oban.Job{}} | {:error, %Ecto.Changeset{}}
  """
  def kickoff(opts \\ []) do
    args = if Keyword.get(opts, :manual, false), do: %{"manual" => true}, else: %{}

    Oban.insert(UpdateWorker.new(args))
  end

  @doc """
  Updates yt-dlp and saves the version to the settings.

  This worker is scheduled to run via the Oban Cron plugin as well as on app boot.
  Both are disabled when the YT_DLP_AUTO_UPDATE environment variable is set to "off"
  (an explicit manual run bypasses that gate).

  Update failures are logged and returned to Oban so callers (like the App Info
  card) see the real outcome - with max_attempts: 1 a failed update is discarded
  without retrying and can't take down the nightly schedule.

  Returns :ok | {:error, String.t()}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"manual" => true}}) do
    Logger.info("Running manual yt-dlp update")

    run_update()
  end

  def perform(%Oban.Job{}) do
    if auto_update_disabled?() do
      Logger.info("Skipping yt-dlp update: YT_DLP_AUTO_UPDATE is set to off")

      :ok
    else
      run_update()
    end
  end

  defp run_update do
    Logger.info("Updating yt-dlp")

    update_result =
      case yt_dlp_runner().update() do
        {:ok, output} ->
          Logger.info("yt-dlp update output: #{output}")

          :ok

        {:error, output} ->
          Logger.error("yt-dlp update failed: #{output}")

          {:error, "yt-dlp update failed: #{output}"}
      end

    case yt_dlp_runner().version() do
      {:ok, yt_dlp_version} ->
        Settings.set(yt_dlp_version: yt_dlp_version)

      err ->
        Logger.error("Unable to read yt-dlp version after update: #{inspect(err)}")
    end

    update_result
  end

  defp auto_update_disabled? do
    Application.get_env(:pinchflat, :yt_dlp_auto_update, "nightly") == "off"
  end

  defp yt_dlp_runner do
    Application.get_env(:pinchflat, :yt_dlp_runner)
  end
end
