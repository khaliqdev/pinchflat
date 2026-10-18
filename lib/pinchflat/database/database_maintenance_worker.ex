defmodule Pinchflat.Database.DatabaseMaintenanceWorker do
  @moduledoc """
  Nightly SQLite maintenance. Checkpoints the WAL back into the main database
  file and refreshes the query planner's statistics via `PRAGMA optimize`.

  This keeps database file and WAL growth in check on long-running instances
  (upstream #887) and is safe to run while the app is live.

  Scheduled nightly via the Oban Cron plugin. Returns :ok
  """

  use Oban.Worker, queue: :local_data, tags: ["local_data"]

  require Logger

  alias Pinchflat.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Running database maintenance")

    log_database_size()
    checkpoint_wal()
    run_optimize()

    :ok
  end

  defp log_database_size do
    with {:ok, %{rows: [[page_count]]}} <- Repo.query("PRAGMA page_count"),
         {:ok, %{rows: [[page_size]]}} <- Repo.query("PRAGMA page_size") do
      size_mb = Float.round(page_count * page_size * 1.0 / (1024 * 1024), 1)
      Logger.info("Database size: #{size_mb}MB")
    else
      err -> Logger.warning("Unable to read database size metrics: #{inspect(err)}")
    end
  end

  defp checkpoint_wal do
    case Repo.query("PRAGMA wal_checkpoint(TRUNCATE)") do
      {:ok, _} -> Logger.info("WAL checkpoint complete")
      {:error, err} -> Logger.error("WAL checkpoint failed: #{inspect(err)}")
    end
  end

  defp run_optimize do
    case Repo.query("PRAGMA optimize") do
      {:ok, _} -> Logger.info("PRAGMA optimize complete")
      {:error, err} -> Logger.error("PRAGMA optimize failed: #{inspect(err)}")
    end
  end
end
