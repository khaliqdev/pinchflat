defmodule Pinchflat.YtDlp.UpdateWorkerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.YtDlp.UpdateWorker

  describe "perform/1" do
    test "calls the yt-dlp runner to update yt-dlp" do
      expect(YtDlpRunnerMock, :update, fn -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, ""} end)

      perform_job(UpdateWorker, %{})
    end

    test "saves the new version to the database" do
      expect(YtDlpRunnerMock, :update, fn -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "1.2.3"} end)

      perform_job(UpdateWorker, %{})

      assert {:ok, "1.2.3"} = Settings.get(:yt_dlp_version)
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
  end
end
