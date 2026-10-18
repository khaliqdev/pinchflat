defmodule Pinchflat.Database.DatabaseMaintenanceWorkerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Database.DatabaseMaintenanceWorker

  @backup_dir Path.join([System.tmp_dir!(), "pf-backup-test-#{System.unique_integer()}"])

  setup do
    Application.put_env(:pinchflat, :backup_directory, @backup_dir)
    File.rm_rf!(@backup_dir)
    File.mkdir_p!(@backup_dir)

    on_exit(fn ->
      Application.delete_env(:pinchflat, :backup_directory)
      File.rm_rf!(@backup_dir)
    end)

    :ok
  end

  describe "perform/1" do
    test "runs maintenance without error" do
      assert :ok = perform_job(DatabaseMaintenanceWorker, %{})
    end
  end

  describe "vacuum_into/2" do
    test "creates a readable copy of the source database" do
      source = Path.join([@backup_dir, "source.db"])
      target = Path.join([@backup_dir, "pinchflat-today.db"])

      {:ok, conn} = Exqlite.Sqlite3.open(source)
      :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE things (id INTEGER)")
      :ok = Exqlite.Sqlite3.execute(conn, "INSERT INTO things VALUES (42)")
      :ok = Exqlite.Sqlite3.close(conn)

      assert :ok = DatabaseMaintenanceWorker.vacuum_into(source, target)
      assert File.exists?(target)

      {:ok, conn} = Exqlite.Sqlite3.open(target)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT id FROM things")
      {:row, [42]} = Exqlite.Sqlite3.step(conn, stmt)
      :ok = Exqlite.Sqlite3.close(conn)
    end
  end

  describe "prune_old_backups/0" do
    test "keeps only the 7 most recent dated backups" do
      for day <- 1..9 do
        date = Date.add(Date.utc_today(), -day) |> Date.to_iso8601()
        File.touch!(Path.join(@backup_dir, "pinchflat-#{date}.db"))
      end

      assert length(File.ls!(@backup_dir)) == 9

      perform_job(DatabaseMaintenanceWorker, %{})

      remaining_dates =
        @backup_dir
        |> File.ls!()
        |> MapSet.new()

      # 7 of the 9 seeded files survive (the 2 oldest are pruned); today's
      # backup may or may not be among them depending on whether the backup
      # itself succeeded before the prune
      assert MapSet.size(remaining_dates) == 7
      assert MapSet.member?(remaining_dates, "pinchflat-#{Date.add(Date.utc_today(), -3) |> Date.to_iso8601()}.db")
      refute MapSet.member?(remaining_dates, "pinchflat-#{Date.add(Date.utc_today(), -9) |> Date.to_iso8601()}.db")
      refute MapSet.member?(remaining_dates, "pinchflat-#{Date.add(Date.utc_today(), -8) |> Date.to_iso8601()}.db")
    end
  end
end
