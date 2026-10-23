defmodule PinchflatWeb.Pages.LogsLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.Logs.LogBuffer
  alias Pinchflat.Pages.LogsLive

  # The app's supervision tree already started the LogBuffer backend; tests
  # run at logger level :critical, so seeding goes through record/3.
  # Reset HERE, synchronously - an on_exit reset runs as a separate task that
  # can interleave with the next test and wipe rows it just seeded
  setup do
    LogBuffer.reset!()
  end

  describe "render/1" do
    test "renders buffered lines in the monospace, theme-aware console block", %{conn: conn} do
      LogBuffer.record(:info, "the ship is fine", %{})

      {:ok, _view, html} = live_isolated(conn, LogsLive, session: %{})

      assert html =~ "the ship is fine"
      assert html =~ "[info] | the ship is fine"
      # The /errors console styling tokens (asserted per token - the class
      # order in the markup differs from the /errors page)
      assert html =~ "font-mono"
      assert html =~ "bg-gray-2"
      assert html =~ "dark:bg-meta-4"
      assert html =~ "border-stroke"
      assert html =~ "dark:border-strokedark"
    end

    test "excludes debug lines by default - the decision that keeps the chatty prod default usable", %{conn: conn} do
      LogBuffer.record(:debug, "chatty debug firehose", %{})
      LogBuffer.record(:error, "an error happened", %{})

      {:ok, _view, html} = live_isolated(conn, LogsLive, session: %{})

      refute html =~ "chatty debug firehose"
      assert html =~ "an error happened"
      # The debug chip is still there (with its buffer count), just off
      assert html =~ "debug"
      assert html =~ "2 buffered since boot"
    end

    test "renders warn-level lines by default (real Logger.warning/1 arrives as legacy :warn)", %{conn: conn} do
      LogBuffer.record(:warn, "a warning the viewer must show", %{})

      {:ok, _view, html} = live_isolated(conn, LogsLive, session: %{})

      assert html =~ "a warning the viewer must show"
      assert html =~ "warning"
    end

    test "shows whole-buffer level counts on the chips", %{conn: conn} do
      LogBuffer.record(:error, "error one", %{})
      LogBuffer.record(:error, "error two", %{})
      LogBuffer.record(:warning, "warning one", %{})

      {:ok, _view, html} = live_isolated(conn, LogsLive, session: %{})

      assert html =~ "error <span"
      assert html =~ "warning <span"
      # Counts come from the whole buffer, even for filtered-out levels
      assert html =~ "3 buffered since boot"
    end

    test "shows source chips derived by the buffer", %{conn: conn} do
      LogBuffer.record(:info, ~s({"worker": "Pinchflat.Downloading.MediaDownloadWorker", "event": "start"}), %{})

      {:ok, _view, html} = live_isolated(conn, LogsLive, session: %{})

      assert html =~ "MediaDownloadWorker"
    end
  end

  describe "handle_event/3 filters" do
    test "toggle-level reveals debug lines with one click", %{conn: conn} do
      LogBuffer.record(:debug, "chatty debug firehose", %{})
      LogBuffer.record(:error, "an error happened", %{})

      {:ok, view, html} = live_isolated(conn, LogsLive, session: %{})

      refute html =~ "chatty debug firehose"

      html = render_click(view, "toggle-level", %{"level" => "debug"})

      assert html =~ "chatty debug firehose"
    end

    test "toggle-level can hide a level again", %{conn: conn} do
      LogBuffer.record(:error, "an error happened", %{})
      LogBuffer.record(:info, "plain info line", %{})

      {:ok, view, _html} = live_isolated(conn, LogsLive, session: %{})

      html = render_click(view, "toggle-level", %{"level" => "error"})

      refute html =~ "an error happened"
      assert html =~ "plain info line"
      # The count chip still reports the buffered errors
      assert html =~ "2 buffered since boot"
    end

    test "search narrows lines case-insensitively", %{conn: conn} do
      LogBuffer.record(:info, "needle in the haystack", %{})
      LogBuffer.record(:info, "unrelated line", %{})

      {:ok, view, html} = live_isolated(conn, LogsLive, session: %{})
      assert html =~ "unrelated line"

      html = render_change(view, "search", %{"search" => "NEEDLE"})

      assert html =~ "needle in the haystack"
      refute html =~ "unrelated line"
    end

    test "select-source filters by the worker/module label and All sources restores", %{conn: conn} do
      LogBuffer.record(:info, ~s({"worker": "Pinchflat.Downloading.MediaDownloadWorker", "event": "start"}), %{})
      LogBuffer.record(:info, "unattributed line", %{})

      {:ok, view, _html} = live_isolated(conn, LogsLive, session: %{})

      html = render_click(view, "select-source", %{"source" => "MediaDownloadWorker"})

      assert html =~ "MediaDownloadWorker"
      refute html =~ "unattributed line"

      html = render_click(view, "select-source", %{"source" => ""})

      assert html =~ "unattributed line"
    end
  end

  describe "follow, pause, and chunked rendering" do
    test "append broadcasts stream new lines without a manual refresh", %{conn: conn} do
      LogBuffer.record(:info, "line from before mount", %{})

      {:ok, view, html} = live_isolated(conn, LogsLive, session: %{})

      assert html =~ "line from before mount"
      refute html =~ "line after mount"

      # The first record consumed the broadcast throttle window; backdate
      # the flush marker through the public table so this tick is armed
      :ets.insert(:log_buffer, {:flush_at, System.system_time(:millisecond) - 501})

      LogBuffer.record(:info, "line after mount", %{})

      assert_eventually(fn -> assert render(view) =~ "line after mount" end)
    end

    test "pausing freezes the view and resuming catches up", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, LogsLive, session: %{})

      html = render_click(view, "toggle-follow")
      assert html =~ "Resume follow"

      LogBuffer.record(:info, "post-pause line", %{})

      # Give the (ignored) broadcast a chance to land before re-rendering
      Process.sleep(100)

      refute render(view) =~ "post-pause line"

      html = render_click(view, "toggle-follow")
      assert html =~ "Pause follow"
      assert html =~ "post-pause line"
    end

    test "show-older loads older chunks beyond the initial window", %{conn: conn} do
      Enum.each(1..250, &LogBuffer.record(:info, "bulk line #{&1}", %{}))

      {:ok, view, html} = live_isolated(conn, LogsLive, session: %{})

      # The initial window renders only the newest chunk. "| bulk line 1<"
      # pins line 1 itself (suffixes like 100/199 don't match it)
      assert html =~ "showing 200 of 250 matching (250 buffered since boot)"
      assert html =~ "bulk line 250"
      refute html =~ "| bulk line 1<"

      html = render_click(view, "show-older")

      assert html =~ "bulk line 1"
      assert html =~ "showing 250 of 250 matching (250 buffered since boot)"
    end

    test "tolerates broadcast noise (empty payloads, foreign events) without crashing", %{conn: conn} do
      LogBuffer.record(:info, "stable line", %{})

      {:ok, view, _html} = live_isolated(conn, LogsLive, session: %{})

      PinchflatWeb.Endpoint.broadcast("log_buffer", "append", nil)
      PinchflatWeb.Endpoint.broadcast("log_buffer", "some_other_event", %{junk: true})

      Process.sleep(100)

      assert render(view) =~ "stable line"
    end
  end

  defp assert_eventually(fun, attempts_left \\ 20) do
    try do
      fun.()
      true
    rescue
      e in ExUnit.AssertionError ->
        if attempts_left <= 1 do
          reraise e, __STACKTRACE__
        else
          Process.sleep(50)
          assert_eventually(fun, attempts_left - 1)
        end
    end
  end
end
