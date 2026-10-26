defmodule Pinchflat.Lifecycle.Notifications.FailureDigestWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures

  alias Pinchflat.Lifecycle.Notifications.FailureDigestWorker
  alias Pinchflat.Settings

  setup do
    Settings.set(failure_notifications: true)
    Settings.set(apprise_server: "json://example.com")
    # A distant cursor; each test overrides or relies on the window including
    # its backdated failures. (Settings has no delete - nil is not storable.)
    Settings.set(
      failure_digest_cursor: DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)
    )

    :ok
  end

  defp backdated_error(title, seconds_ago) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    media_item = media_item_fixture(%{title: title, last_error: "ERROR: it broke"})

    # updated_at is second-resolution and set by touches; backdate via a direct
    # no-touch update so the window arithmetic is deterministic
    {:ok, _} =
      media_item
      |> Ecto.Changeset.change(updated_at: DateTime.add(now, -seconds_ago, :second))
      |> Pinchflat.Repo.update(force: true)

    media_item
  end

  defp cursor do
    case Settings.get(:failure_digest_cursor) do
      {:ok, %DateTime{} = c} -> c
      _ -> nil
    end
  end

  describe "perform/1" do
    test "does nothing when the setting is off" do
      Settings.set(failure_notifications: false)
      media_item_fixture(%{last_error: "boom"})

      # AppriseRunnerMock has no expectation set, so this raises if called
      assert :ok = perform_job(FailureDigestWorker, %{})
    end

    test "successful delivery advances the cursor through the completed window" do
      backdated_error("Broken Item", 600)

      expect(AppriseRunnerMock, :run, fn _servers, opts ->
        assert opts[:title] =~ "Download failures"
        assert opts[:body] =~ "Broken Item"
        assert opts[:body] =~ "1 new download failure"

        {:ok, ""}
      end)

      assert :ok = perform_job(FailureDigestWorker, %{})

      # the cursor moved past the failure's timestamp: a re-run sends nothing
      expect(AppriseRunnerMock, :run, 0, fn _servers, _opts -> flunk("must not resend") end)
      assert :ok = perform_job(FailureDigestWorker, %{})
    end

    test "failed delivery preserves the cursor and retries the pending window" do
      backdated_error("Broken Item", 600)

      expect(AppriseRunnerMock, :run, fn _servers, _opts -> {:error, :delivery_failed} end)
      # the failure surfaces as a failed job (max_attempts: 1) - visible in the
      # Oban dashboard, while the preserved cursor makes the next cron retry
      assert {:error, :delivery_failed} = perform_job(FailureDigestWorker, %{})
      failed_cursor = cursor()
      assert failed_cursor

      # :no_servers must also count as a failure, not an acknowledgement
      expect(AppriseRunnerMock, :run, fn _servers, _opts -> {:error, :no_servers} end)
      assert {:error, :no_servers} = perform_job(FailureDigestWorker, %{})
      assert cursor() == failed_cursor

      # next successful delivery covers the still-pending window and advances
      expect(AppriseRunnerMock, :run, fn _servers, _opts -> {:ok, ""} end)
      assert :ok = perform_job(FailureDigestWorker, %{})
      assert DateTime.compare(cursor(), failed_cursor) == :gt
    end

    test "an empty window advances the cursor without sending" do
      previous = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      Settings.set(failure_digest_cursor: previous)

      expect(AppriseRunnerMock, :run, 0, fn _servers, _opts -> flunk("must not send") end)
      assert :ok = perform_job(FailureDigestWorker, %{})

      assert DateTime.compare(cursor(), previous) == :gt
    end

    test "a digest includes more than 100 failures sharing one timestamp" do
      # A single completed second shared by all 101 rows: advancing to that
      # second must cover every row, not just the 100 sampled
      shared = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)

      Enum.each(1..101, fn i ->
        item = backdated_error("Broken #{i}", 600)

        {:ok, _} =
          item
          |> Ecto.Changeset.change(updated_at: shared)
          |> Pinchflat.Repo.update(force: true)
      end)

      expect(AppriseRunnerMock, :run, fn _servers, opts ->
        assert opts[:body] =~ "101 new download failure"
        {:ok, ""}
      end)

      assert :ok = perform_job(FailureDigestWorker, %{})

      expect(AppriseRunnerMock, :run, 0, fn _servers, _opts -> flunk("must not resend") end)
      assert :ok = perform_job(FailureDigestWorker, %{})
    end
  end
end
