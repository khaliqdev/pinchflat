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
    backup_database()
    prune_old_backups()

    :ok
  end

  # Nightly consistent snapshot of the main database file via VACUUM INTO.
  # Operation hardening (WAL, checkpoints) is not loss protection - this is
  # the cheapest insurance for a single-file store of the user's whole library
  # metadata (sources, settings, error history).
  defp backup_database do
    backup_dir = Application.get_env(:pinchflat, :backup_directory)
    database_path = Repo.config()[:database]

    if is_binary(backup_dir) && is_binary(database_path) do
      File.mkdir_p!(backup_dir)

      date = DateTime.utc_now() |> DateTime.to_date() |> Date.to_iso8601()
      backup_path = Path.join(backup_dir, "pinchflat-#{date}.db")
      safe_path = String.replace(backup_path, "'", "''")

      case vacuum_into(database_path, safe_path) do
        :ok -> Logger.info("Database backed up to #{backup_path}")
        {:error, err} -> Logger.error("Database backup failed: #{inspect(err)}")
      end
    end
  end

  # Runs on its own connection because VACUUM cannot execute inside the
  # sandbox/transaction wrappers Ecto may have open
  def vacuum_into(source_path, safe_backup_path) do
    {:ok, conn} = Exqlite.Sqlite3.open(source_path)

    try do
      case Exqlite.Sqlite3.execute(conn, "VACUUM INTO '#{safe_backup_path}'") do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    after
      :ok = Exqlite.Sqlite3.close(conn)
    end
  end

  defp prune_old_backups do
    backup_dir = Application.get_env(:pinchflat, :backup_directory)

    if is_binary(backup_dir) do
      backup_dir
      |> File.ls!()
      |> Enum.filter(&Regex.match?(~r/^pinchflat-\d{4}-\d{2}-\d{2}\.db$/, &1))
      |> Enum.sort()
      |> Enum.split(-7)
      |> elem(0)
      |> Enum.each(&File.rm(Path.join(backup_dir, &1)))
    end
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
