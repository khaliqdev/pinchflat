defmodule Pinchflat.Downloading.DownloadProgressTest do
  use Pinchflat.DataCase

  alias Pinchflat.Downloading.DownloadProgress

  # The app's supervision tree already started the DownloadProgress server
  # (mix test boots the full app), so we only reset its table here - never
  # start_supervised!, which would raise {:error, {:already_started, pid}}.
  setup do
    DownloadProgress.reset!()

    on_exit(&DownloadProgress.reset!/0)
  end

  describe "record_line/2 parsing" do
    test "records percent, speed, and eta from a full progress line" do
      line = ~s({"downloaded_bytes": 524288, "total_bytes": 1048576, "_speed_str": "2.00MiB/s", "_eta_str": "00:30"})

      :ok = DownloadProgress.record_line(1, line)

      assert %{percent: 50.0, speed: "2.00MiB/s", eta: "00:30"} = DownloadProgress.get(1)
    end

    test "ignores non-JSON lines without raising" do
      :ok = DownloadProgress.record_line(1, "WARNING: [generic] Unable to download webpage")
      :ok = DownloadProgress.record_line(1, "")
      :ok = DownloadProgress.record_line(1, "not json at all")

      assert DownloadProgress.get(1) == nil
    end

    test "ignores JSON non-objects (numbers, arrays, null)" do
      :ok = DownloadProgress.record_line(1, "123")
      :ok = DownloadProgress.record_line(1, "[1,2,3]")
      :ok = DownloadProgress.record_line(1, "null")

      assert DownloadProgress.get(1) == nil
    end

    test "normalizes Unknown and NA sentinels to nil" do
      line = ~s({"downloaded_bytes": 1024, "total_bytes": 4096, "_speed_str": " Unknown B/s", "_eta_str": "Unknown"})

      :ok = DownloadProgress.record_line(1, line)

      assert %{percent: 25.0, speed: nil, eta: nil} = DownloadProgress.get(1)
    end

    test "coalesces total_bytes_estimate when total_bytes is absent" do
      line = ~s({"downloaded_bytes": 524288, "total_bytes_estimate": 2097152})

      :ok = DownloadProgress.record_line(1, line)

      assert %{percent: 25.0} = DownloadProgress.get(1)
    end

    test "prefers exact total_bytes over total_bytes_estimate" do
      line = ~s({"downloaded_bytes": 512, "total_bytes": 1024, "total_bytes_estimate": 4096})

      :ok = DownloadProgress.record_line(1, line)

      assert %{percent: 50.0} = DownloadProgress.get(1)
    end

    test "returns nil percent when no total is known" do
      line = ~s({"downloaded_bytes": 2048, "_speed_str": "1.00MiB/s"})

      :ok = DownloadProgress.record_line(1, line)

      assert %{percent: nil, speed: "1.00MiB/s"} = DownloadProgress.get(1)
    end

    test "returns nil percent (without raising) when total is zero" do
      line = ~s({"downloaded_bytes": 0, "total_bytes": 0})

      :ok = DownloadProgress.record_line(1, line)

      assert %{percent: nil} = DownloadProgress.get(1)
    end

    test "clamps percent above 100 and below 0" do
      :ok = DownloadProgress.record_line(1, ~s({"downloaded_bytes": 120, "total_bytes": 100}))
      assert %{percent: 100.0} = DownloadProgress.get(1)

      :ok = DownloadProgress.record_line(1, ~s({"downloaded_bytes": -5, "total_bytes": 100}))
      assert %{percent: 0.0} = DownloadProgress.get(1)
    end

    test "accepts cleanly-numeric strings for numeric fields" do
      line = ~s({"downloaded_bytes": "50", "total_bytes": "200"})

      :ok = DownloadProgress.record_line(1, line)

      assert %{percent: 25.0} = DownloadProgress.get(1)
    end

    test "neither raises nor writes a bogus percent for humanized string numerics" do
      line = ~s({"downloaded_bytes": "45.32MiB", "total_bytes": "Unknown"})

      :ok = DownloadProgress.record_line(1, line)

      assert %{percent: nil} = DownloadProgress.get(1)
    end

    test "rounds percent to one decimal place" do
      line = ~s({"downloaded_bytes": 1, "total_bytes": 3})

      :ok = DownloadProgress.record_line(1, line)

      assert %{percent: 33.3} = DownloadProgress.get(1)
    end

    test "never raises for non-binary input" do
      :ok = DownloadProgress.record_line(1, nil)
      :ok = DownloadProgress.record_line(1, :ok)

      assert DownloadProgress.get(1) == nil
    end
  end

  describe "record_line/2 broadcasting" do
    setup do
      PinchflatWeb.Endpoint.subscribe("download_progress")

      on_exit(fn ->
        PinchflatWeb.Endpoint.unsubscribe("download_progress")
      end)

      :ok
    end

    test "broadcasts a progress event for a new item" do
      :ok =
        DownloadProgress.record_line(
          1,
          ~s({"downloaded_bytes": 50, "total_bytes": 100, "_speed_str": "1.00MiB/s", "_eta_str": "00:10"})
        )

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "download_progress",
        event: "progress",
        payload: %{media_item_id: 1, percent: 50.0, speed: "1.00MiB/s", eta: "00:10"}
      }
    end

    test "throttles broadcasts to one per interval per item" do
      :ok = DownloadProgress.record_line(1, ~s({"downloaded_bytes": 10, "total_bytes": 100}))
      :ok = DownloadProgress.record_line(1, ~s({"downloaded_bytes": 50, "total_bytes": 100}))
      :ok = DownloadProgress.record_line(1, ~s({"downloaded_bytes": 90, "total_bytes": 100}))

      # The last-wins row is kept even though the broadcasts are throttled
      assert %{percent: 90.0} = DownloadProgress.get(1)

      assert_receive %Phoenix.Socket.Broadcast{topic: "download_progress", event: "progress"}

      refute_received %Phoenix.Socket.Broadcast{topic: "download_progress", event: "progress"}
    end

    test "does not broadcast for junk lines" do
      :ok = DownloadProgress.record_line(1, "WARNING: junk")

      refute_received %Phoenix.Socket.Broadcast{topic: "download_progress", event: "progress"}
    end

    test "broadcasts independently per media item" do
      :ok = DownloadProgress.record_line(1, ~s({"downloaded_bytes": 10, "total_bytes": 100}))
      :ok = DownloadProgress.record_line(2, ~s({"downloaded_bytes": 20, "total_bytes": 100}))

      assert_receive %Phoenix.Socket.Broadcast{payload: %{media_item_id: 1}}
      assert_receive %Phoenix.Socket.Broadcast{payload: %{media_item_id: 2}}
    end
  end

  describe "get/1, snapshot/0, clear/1, and reset!/0" do
    test "get returns nil for unknown items" do
      assert DownloadProgress.get(999) == nil
    end

    test "snapshot returns a percent/speed/eta map keyed by media item id" do
      :ok = DownloadProgress.record_line(1, ~s({"downloaded_bytes": 50, "total_bytes": 100, "_speed_str": "2.00MiB/s"}))
      :ok = DownloadProgress.record_line(2, ~s({"downloaded_bytes": 10, "total_bytes": "Unknown"}))

      assert DownloadProgress.snapshot() == %{
               1 => %{percent: 50.0, speed: "2.00MiB/s", eta: nil},
               2 => %{percent: nil, speed: nil, eta: nil}
             }
    end

    test "clear removes the row and is idempotent" do
      :ok = DownloadProgress.record_line(1, ~s({"downloaded_bytes": 50, "total_bytes": 100}))

      :ok = DownloadProgress.clear(1)
      :ok = DownloadProgress.clear(1)

      assert DownloadProgress.get(1) == nil
    end

    test "reset! empties the table" do
      :ok = DownloadProgress.record_line(1, ~s({"downloaded_bytes": 50, "total_bytes": 100}))
      :ok = DownloadProgress.record_line(2, ~s({"downloaded_bytes": 50, "total_bytes": 100}))

      :ok = DownloadProgress.reset!()

      assert DownloadProgress.snapshot() == %{}
    end
  end

  describe "sweep/0" do
    test "removes rows stale past the TTL but keeps fresh ones" do
      :ok = DownloadProgress.record_line(1, ~s({"downloaded_bytes": 50, "total_bytes": 100}))

      # Backdate item 1 and add an already-stale item 2 directly through the
      # public table (rows are plain {id, map} tuples)
      stale_row = DownloadProgress.get(1) |> Map.put(:updated_at, System.system_time(:millisecond) - 601_000)
      :ets.insert(:download_progress, {1, stale_row})
      :ets.insert(:download_progress, {2, Map.put(stale_row, :updated_at, System.system_time(:millisecond) - 700_000)})

      :ok = DownloadProgress.record_line(3, ~s({"downloaded_bytes": 50, "total_bytes": 100}))

      assert DownloadProgress.sweep() == 2

      assert DownloadProgress.get(1) == nil
      assert DownloadProgress.get(2) == nil
      assert %{percent: 50.0} = DownloadProgress.get(3)
    end
  end

  describe "missing ETS table resilience" do
    test "degrades to empty when the ETS table does not exist" do
      # Delete the table without stopping its owner: race-free way to
      # simulate a reader outliving the table (code-reloaded LiveViews,
      # restarts mid-flight). Stopping the GenServer instead races the
      # supervisor's immediate restart.
      true = :ets.delete(:download_progress)

      assert DownloadProgress.snapshot() == %{}
      assert is_nil(DownloadProgress.get(1))
      assert :ok = DownloadProgress.clear(1)
      assert :ok = DownloadProgress.record_line(1, ~s({"downloaded_bytes": "5"}))

      # Restore: the supervisor restarts the (still-running, table-less)
      # child's table via a stop-and-restart, recreated in init
      :ok = GenServer.stop(DownloadProgress)

      wait_until_table()
    end

    defp wait_until_table(iterations \\ 50) do
      if :ets.whereis(:download_progress) == :undefined and iterations > 0 do
        Process.sleep(10)
        wait_until_table(iterations - 1)
      end
    end
  end
end
