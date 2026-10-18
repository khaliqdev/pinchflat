defmodule Pinchflat.YtDlp.UpdateWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    tags: ["local_data"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Settings

  @doc """
  Starts the yt-dlp update worker. Does not attach it to a task like `kickoff_with_task/2`

  Returns {:ok, %Oban.Job{}} | {:error, %Ecto.Changeset{}}
  """
  def kickoff do
    Oban.insert(UpdateWorker.new(%{}))
  end

  @doc """
  Updates yt-dlp and saves the version to the settings.

  This worker is scheduled to run via the Oban Cron plugin as well as on app boot.
  Both are disabled when the YT_DLP_AUTO_UPDATE environment variable is set to "off".

  Update failures are logged but never crash the job so that a failed update
  can't take down the nightly schedule.

  Returns :ok
  """
  @impl Oban.Worker
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

    case yt_dlp_runner().update() do
      {:ok, output} -> Logger.info("yt-dlp update output: #{output}")
      {:error, output} -> Logger.error("yt-dlp update failed: #{output}")
    end

    case yt_dlp_runner().version() do
      {:ok, yt_dlp_version} ->
        Settings.set(yt_dlp_version: yt_dlp_version)

      err ->
        Logger.error("Unable to read yt-dlp version after update: #{inspect(err)}")
    end

    :ok
  end

  defp auto_update_disabled? do
    Application.get_env(:pinchflat, :yt_dlp_auto_update, "nightly") == "off"
  end

  defp yt_dlp_runner do
    Application.get_env(:pinchflat, :yt_dlp_runner)
  end
end
