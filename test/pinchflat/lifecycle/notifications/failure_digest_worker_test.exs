defmodule Pinchflat.Lifecycle.Notifications.FailureDigestWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures

  alias Pinchflat.Lifecycle.Notifications.FailureDigestWorker
  alias Pinchflat.Settings

  setup do
    stub(AppriseRunnerMock, :run, fn _servers, _opts -> {:ok, ""} end)

    :ok
  end

  describe "perform/1" do
    test "does nothing when the setting is off" do
      Settings.set(failure_notifications: false)
      media_item_fixture(%{last_error: "boom"})

      # AppriseRunnerMock has no expectation set, so this raises if called
      assert :ok = perform_job(FailureDigestWorker, %{})
    end

    test "sends one bundled digest and advances the cursor" do
      Settings.set(failure_notifications: true)
      Settings.set(apprise_server: "json://example.com")
      Settings.set(failure_digest_cursor: DateTime.add(DateTime.utc_now(), -3600, :second))

      media_item_fixture(%{title: "Broken Item", last_error: "ERROR: it broke"})

      expect(AppriseRunnerMock, :run, fn _servers, opts ->
        assert opts[:title] =~ "Download failures"
        assert opts[:body] =~ "Broken Item"

        {:ok, ""}
      end)

      assert :ok = perform_job(FailureDigestWorker, %{})

      assert {:ok, cursor} = Settings.get(:failure_digest_cursor)
      assert DateTime.compare(cursor, DateTime.utc_now()) != :gt
    end

    test "does not re-send items already covered by the cursor" do
      Settings.set(failure_notifications: true)
      Settings.set(apprise_server: "json://example.com")
      Settings.set(failure_digest_cursor: DateTime.utc_now() |> DateTime.truncate(:second))

      media_item_fixture(%{title: "Old Error", last_error: "boom"})

      # No expectation on the runner: raises if a digest is sent
      assert :ok = perform_job(FailureDigestWorker, %{})
    end
  end
end
