defmodule Pinchflat.YtDlp.UpdateWorkerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.YtDlp.UpdateWorker

  describe "kickoff/1" do
    test "enqueues an auto-gated job by default" do
      assert {:ok, %Oban.Job{args: args}} = UpdateWorker.kickoff()

      assert args == %{}
    end

    test "enqueues a manual job when the manual option is set" do
      assert {:ok, %Oban.Job{args: %{"manual" => true}}} = UpdateWorker.kickoff(manual: true)
    end
  end

  describe "perform/1" do
    test "calls the yt-dlp runner to update yt-dlp" do
      expect(YtDlpRunnerMock, :update, fn -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, ""} end)

      assert :ok = perform_job(UpdateWorker, %{})
    end

    test "saves the new version to the database" do
      expect(YtDlpRunnerMock, :update, fn -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "1.2.3"} end)

      perform_job(UpdateWorker, %{})

      assert {:ok, "1.2.3"} = Settings.get(:yt_dlp_version)
    end

    test "returns an error when the update fails" do
      expect(YtDlpRunnerMock, :update, fn -> {:error, "could not update"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "1.0.0"} end)

      assert {:error, "yt-dlp update failed: could not update"} = perform_job(UpdateWorker, %{})
    end

    test "saves the version even when the update fails" do
      expect(YtDlpRunnerMock, :update, fn -> {:error, "could not update"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "1.0.0"} end)

      perform_job(UpdateWorker, %{})

      assert {:ok, "1.0.0"} = Settings.get(:yt_dlp_version)
    end

    test "does not update yt-dlp when auto-update is off" do
      Application.put_env(:pinchflat, :yt_dlp_auto_update, "off")

      on_exit(fn -> Application.delete_env(:pinchflat, :yt_dlp_auto_update) end)

      # No Mox expectations are set, so this raises if the runner is touched
      perform_job(UpdateWorker, %{})
    end

    test "updates yt-dlp even when auto-update is off when the job is manual" do
      Application.put_env(:pinchflat, :yt_dlp_auto_update, "off")

      on_exit(fn -> Application.delete_env(:pinchflat, :yt_dlp_auto_update) end)

      expect(YtDlpRunnerMock, :update, fn -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "1.2.3"} end)

      assert :ok = perform_job(UpdateWorker, %{"manual" => true})

      assert {:ok, "1.2.3"} = Settings.get(:yt_dlp_version)
    end

    test "returns an error for a failed manual update even when auto-update is off" do
      Application.put_env(:pinchflat, :yt_dlp_auto_update, "off")

      on_exit(fn -> Application.delete_env(:pinchflat, :yt_dlp_auto_update) end)

      expect(YtDlpRunnerMock, :update, fn -> {:error, "could not update"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "1.0.0"} end)

      assert {:error, "yt-dlp update failed: could not update"} = perform_job(UpdateWorker, %{"manual" => true})
    end
  end
end
