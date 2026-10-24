defmodule Pinchflat.Logs.LogBufferTest do
  use Pinchflat.DataCase

  alias Pinchflat.Logs.LogBuffer

  # The pipeline test calls the Logger macros directly
  require Logger

  # The app's supervision tree already started the LogBuffer server (mix
  # test boots the full app), so we only reset its table here - never
  # start_supervised!, which would raise {:error, {:already_started, pid}}.
  # The reset happens HERE, synchronously: an on_exit reset runs as a
  # separate task that can interleave with the next test, wiping rows that
  # test just seeded (the empty-buffer failures this file shipped with).
  setup do
    LogBuffer.reset!()
  end

  describe "record/3 storage and ring behaviour" do
    test "stores lines with console-formatted output, oldest first" do
      :ok = LogBuffer.record(:info, "hello world", %{})

      assert [%{seq: 1, level: :info, message: "hello world"}] = LogBuffer.all()

      line = LogBuffer.all() |> List.first() |> Map.get(:line)
      assert line =~ "[info] | hello world"
      assert line =~ ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}/
    end

    test "assigns increasing seqs and orders oldest-first" do
      Enum.each(1..3, &LogBuffer.record(:info, "line #{&1}", %{}))

      assert Enum.map(LogBuffer.all(), & &1.seq) == [1, 2, 3]
      assert Enum.map(LogBuffer.all(), & &1.message) == ["line 1", "line 2", "line 3"]
    end

    test "recent/1 returns the newest n lines, oldest first" do
      Enum.each(1..5, &LogBuffer.record(:info, "line #{&1}", %{}))

      assert Enum.map(LogBuffer.recent(2), & &1.message) == ["line 4", "line 5"]
    end

    test "since/1 returns only lines newer than the given seq, oldest first" do
      Enum.each(1..4, &LogBuffer.record(:info, "line #{&1}", %{}))

      assert Enum.map(LogBuffer.since(2), & &1.message) == ["line 3", "line 4"]
      assert LogBuffer.since(99) == []
    end

    test "trims the ring to the cap once full, dropping the oldest lines" do
      # Shrink the cap directly through the public table, like the
      # DownloadProgress sweep test backdates rows
      :ets.insert(:log_buffer, {:cap, 3})

      Enum.each(1..5, &LogBuffer.record(:info, "line #{&1}", %{}))

      assert LogBuffer.total() == 3
      assert Enum.map(LogBuffer.all(), & &1.message) == ["line 3", "line 4", "line 5"]
    end

    test "normalizes the legacy :warn level to :warning so real warnings match the viewer's chips" do
      # Logger.Backends.Handler bridges real Logger.warning/1 calls in as
      # :warn (Erlang :warning -> legacy atom); storage must canonicalize
      LogBuffer.record(:warn, "legacy warn", %{})

      assert [%{level: :warning, message: "legacy warn"}] = LogBuffer.all()
      assert %{warning: 1, debug: 0, info: 0, error: 0} = LogBuffer.counts()
    end

    test "buffer cap is LOG_BUFFER_LINES-tunable via the environment" do
      System.put_env("LOG_BUFFER_LINES", "2")

      # reset! re-reads the env and reseeds the cap row
      :ok = LogBuffer.reset!()

      Enum.each(1..4, &LogBuffer.record(:info, "env line #{&1}", %{}))

      assert LogBuffer.total() == 2
      assert Enum.map(LogBuffer.all(), & &1.message) == ["env line 3", "env line 4"]
    after
      # Restored in-test (not on_exit) so a shuffled later test's reset!
      # can't read this test's cap override
      System.delete_env("LOG_BUFFER_LINES")
    end
  end

  describe "counts/0 and source classification" do
    test "counts buffered lines per level across the whole buffer" do
      LogBuffer.record(:error, "error one", %{})
      LogBuffer.record(:error, "error two", %{})
      LogBuffer.record(:warning, "warning one", %{})
      LogBuffer.record(:debug, "debug one", %{})

      assert %{error: 2, warning: 1, debug: 1, info: 0} = LogBuffer.counts()
    end

    test "classifies Oban's JSON-encoded telemetry messages by their worker" do
      message =
        Jason.encode!(%{
          "attempt" => 1,
          "event" => "start",
          "queue" => "media_fetching",
          "worker" => "Pinchflat.Downloading.MediaDownloadWorker"
        })

      LogBuffer.record(:info, message, %{})

      assert [%{source: "MediaDownloadWorker"}] = LogBuffer.all()
      assert LogBuffer.sources() == ["MediaDownloadWorker"]
    end

    test "classifies yt-dlp command wrapper lines" do
      LogBuffer.record(:info, "[command_wrapper]: /usr/local/bin/yt-dlp called with: some-url", %{})

      assert [%{source: "YtDlp"}] = LogBuffer.all()
    end

    test "classifies messages that embed their module (Pinchflat workers)" do
      LogBuffer.record(:error, "Pinchflat.Downloading.MediaDownloadWorker discarded: test", %{})
      LogBuffer.record(:info, "Pinchflat.YtDlp.UpdateWorker did something", %{})

      assert [%{source: "MediaDownloadWorker"}, %{source: "UpdateWorker"}] = LogBuffer.all()
      assert LogBuffer.sources() == ["MediaDownloadWorker", "UpdateWorker"]
    end

    test "prefers Logger metadata when present (worker and repo keys)" do
      LogBuffer.record(:info, "whatever", %{worker: Pinchflat.Downloading.MediaDownloadWorker})
      LogBuffer.record(:debug, "QUERY OK", %{repo: Pinchflat.Repo})

      assert [%{source: "MediaDownloadWorker"}, %{source: "Ecto"}] = LogBuffer.all()
    end

    test "classifies Phoenix request logs and leaves unidentified lines unfiltered-out" do
      LogBuffer.record(:info, "GET /sources", %{})
      LogBuffer.record(:info, "no identity here", %{})

      assert [%{source: "Phoenix"}, %{source: nil}] = LogBuffer.all()
      # nil-source lines are simply not offered as a chip
      assert LogBuffer.sources() == ["Phoenix"]
    end
  end

  describe "redaction" do
    test "masks basic-auth URLs before storage" do
      LogBuffer.record(:info, "https://user:s3cret@logs.example.com/path", %{})

      assert [%{message: "https://user:****@logs.example.com/path"}] = LogBuffer.all()
    end

    test "masks query-string credentials (YouTube API keys, tokens, passwords)" do
      LogBuffer.record(:info, "https://www.youtube.com/watch?v=abc&key=AIzaSYs3cret123", %{})
      LogBuffer.record(:info, "https://api.example.com/x?token=abcdef123456", %{})
      LogBuffer.record(:info, "https://api.example.com/y?Password=hunter2&other=plain", %{})

      messages = Enum.map(LogBuffer.all(), & &1.message)

      assert "https://www.youtube.com/watch?v=abc&key=****" in messages
      assert "https://api.example.com/x?token=****" in messages
      assert "https://api.example.com/y?Password=****&other=plain" in messages
    end

    test "masks Authorization header values" do
      LogBuffer.record(:info, "request failed with header Authorization: Bearer eyJhbGciOi.abc.def", %{})

      assert [%{message: message}] = LogBuffer.all()
      assert message =~ "Authorization: Bearer ****"
      refute message =~ "eyJhbGciOi"
    end

    test "masks bare credentials, JSON-body token fields, and free-standing AIza keys" do
      LogBuffer.record(:info, "key=supersecret123 at line start", %{})
      LogBuffer.record(:info, ~s({"worker": "ObanWorker", "api_key": "AIzaSyAbcdef1234567890"}), %{})
      LogBuffer.record(:info, "failed with key AIzaSyAbcdef1234567890 in args", %{})

      messages = Enum.map(LogBuffer.all(), & &1.message)

      assert "key=**** at line start" in messages
      # Non-secret JSON fields survive the pass
      assert ~s({"worker": "ObanWorker", "api_key": "****"}) in messages
      assert "failed with key AIza**** in args" in messages
    end

    test "leaves plain text untouched" do
      LogBuffer.record(:info, "no secrets: https://example.com/plain?b=1", %{})

      assert [%{message: "no secrets: https://example.com/plain?b=1"}] = LogBuffer.all()
    end

    test "redacts metadata string values too" do
      LogBuffer.record(:info, "with metadata", %{request_id: "token=supersecret"})

      assert [%{metadata: %{request_id: "token=****"}}] = LogBuffer.all()
    end
  end

  describe "broadcasting" do
    setup do
      # The throttle state survives reset!-style bookkeeping only through
      # this row; re-arm it so this suite is timing-independent
      :ets.insert(:log_buffer, {:flush_at, 0})

      PinchflatWeb.Endpoint.subscribe("log_buffer")

      on_exit(fn ->
        PinchflatWeb.Endpoint.unsubscribe("log_buffer")
      end)

      :ok
    end

    test "broadcasts an append event with the current seq for the viewer" do
      :ok = LogBuffer.record(:info, "broadcast me", %{})

      assert_receive %Phoenix.Socket.Broadcast{topic: "log_buffer", event: "append", payload: %{seq: 1}}
    end

    test "throttles broadcasts to one per interval - bursts stay off the wire" do
      Enum.each(1..10, &LogBuffer.record(:info, "burst line #{&1}", %{}))

      assert_receive %Phoenix.Socket.Broadcast{topic: "log_buffer", event: "append"}

      # The rows all landed even though the broadcast was throttled
      assert LogBuffer.total() == 10

      refute_received %Phoenix.Socket.Broadcast{topic: "log_buffer", event: "append"}
    end

    test "broadcasts again once the interval has elapsed" do
      :ok = LogBuffer.record(:info, "first", %{})
      :ok = LogBuffer.record(:info, "second", %{})

      assert_receive %Phoenix.Socket.Broadcast{topic: "log_buffer", event: "append", payload: %{seq: 1}}
      refute_received %Phoenix.Socket.Broadcast{topic: "log_buffer", event: "append", payload: %{seq: 2}}

      # Backdate the flush marker through the public table instead of
      # sleeping out the interval
      :ets.insert(:log_buffer, {:flush_at, System.system_time(:millisecond) - 501})

      :ok = LogBuffer.record(:info, "third", %{})

      assert_receive %Phoenix.Socket.Broadcast{topic: "log_buffer", event: "append", payload: %{seq: 3}}
    end
  end

  describe "failure isolation" do
    test "never raises for hostile input - bad lines are dropped, not fatal" do
      assert :ok = LogBuffer.record(:info, nil, %{})
      assert :ok = LogBuffer.record(:info, {:not, :a, :string}, %{weird: make_ref()})
      assert :ok = LogBuffer.record(:error, ["nested", [:iodata, "list"]], nil)
      assert :ok = LogBuffer.record(:bogus_level, "level is just stored", %{})

      entries = LogBuffer.all()

      assert length(entries) == 4
      assert Enum.all?(entries, &is_binary(&1.message))
      assert Enum.all?(entries, &is_map(&1.metadata))
    end

    test "clamps pathological line lengths instead of blowing the memory budget" do
      huge_line = String.duplicate("x", 100_000)

      :ok = LogBuffer.record(:info, huge_line, %{})

      assert [%{message: message}] = LogBuffer.all()
      assert byte_size(message) < 100_000
    end

    test "degrades to empty when the ETS table does not exist" do
      # Delete the table without stopping its owner: race-free way to
      # simulate a reader outliving the table. Stopping the GenServer
      # instead races the supervisor's immediate restart.
      true = :ets.delete(:log_buffer)

      assert LogBuffer.all() == []
      assert LogBuffer.total() == 0
      assert LogBuffer.counts() == %{debug: 0, info: 0, warning: 0, error: 0}
      assert LogBuffer.sources() == []
      assert LogBuffer.recent(5) == []

      assert :ok = LogBuffer.record(:info, "dropped line", %{})
      assert :ok = LogBuffer.reset!()

      # Restore: the supervisor restarts the (still-running, table-less)
      # child's table via a stop-and-restart, recreated in init
      :ok = GenServer.stop(LogBuffer)

      wait_until_table()
    end
  end

  test "the Logger pipeline feeds the buffer end-to-end" do
    # Tests run at logger level :critical; raise it temporarily so a real
    # Logger call exercises the backend callback path. Restored in-test (not
    # on_exit) so the raised window can't leak into a shuffled neighbor
    Logger.configure(level: :info)

    try do
      Logger.info("logged through the real pipeline")
      Logger.warning("warned through the real pipeline")

      assert_eventually(fn ->
        # Not a strict shape match: while the level is raised, unrelated app
        # logs (if any) may land in the buffer too
        assert Enum.any?(
                 LogBuffer.all(),
                 &(&1.message == "logged through the real pipeline" and &1.level == :info)
               )

        # The Erlang :warning -> :warn bridge must land as the canonical
        # :warning, or the viewer's warning chip can never match it
        assert Enum.any?(
                 LogBuffer.all(),
                 &(&1.message == "warned through the real pipeline" and &1.level == :warning)
               )
      end)
    after
      Logger.configure(level: :critical)
    end
  end

  test "the Logger pipeline preserves metadata (the bridge hands keyword lists, not maps)" do
    # Same raised-level window as the pipeline test above; restored in-test so
    # it can't leak into a shuffled neighbor
    Logger.configure(level: :info)

    try do
      Logger.info("metadata through the real pipeline", request_id: "req-123")

      assert_eventually(fn ->
        # Not a strict shape match: unrelated app logs may share the window
        entry = Enum.find(LogBuffer.all(), &(&1.message == "metadata through the real pipeline"))

        # The bridge's keyword list must survive sanitization as a map
        assert %{metadata: %{request_id: "req-123"}} = entry

        # ...and render in the line the viewer and export display
        assert entry.line =~ "request_id=req-123"
      end)
    after
      Logger.configure(level: :critical)
    end
  end

  defp wait_until_table(iterations \\ 50) do
    if :ets.whereis(:log_buffer) == :undefined and iterations > 0 do
      Process.sleep(10)
      wait_until_table(iterations - 1)
    end
  end

  defp assert_eventually(fun, attempts_left \\ 50) do
    try do
      fun.()
      true
    rescue
      e in ExUnit.AssertionError ->
        if attempts_left <= 1 do
          reraise e, __STACKTRACE__
        else
          Process.sleep(10)
          assert_eventually(fun, attempts_left - 1)
        end
    end
  end

  describe "redaction of Phoenix inspect-style credential pairs" do
    test "masks token => \"...\" pairs as emitted by LiveView param logging" do
      LogBuffer.reset!()

      LogBuffer.record(
        :info,
        ~s(Parameters: %{"_csrf_token" => "RigBMTUtSECRET", "_mounts" => "0"} |),
        %{}
      )

      [entry] = LogBuffer.all()
      refute entry.line =~ "RigBMTUtSECRET"
      assert entry.line =~ ~s("_csrf_token" => "****")
      # non-credential keys stay readable
      assert entry.line =~ ~s("_mounts" => "0")
    end
  end

  describe "format_line/2 compact viewer rendering" do
    test "keeps timestamp, level, module, request_id and message; drops Erlang metadata" do
      entry = %{
        time: {{2026, 10, 24}, {12, 0, 0, 123}},
        level: :info,
        message: "the redacted message",
        metadata: %{
          "module" => "Elixir.Phoenix.Logger",
          "function" => "phoenix_endpoint_start/4",
          "file" => "lib/phoenix/logger.ex",
          "gl" => "#PID<0.1.0>",
          request_id: "req-42"
        },
        source: "Logger",
        line: "FULL docker-logs line with pid and file"
      }

      compact = LogBuffer.format_line(entry, :compact)

      assert compact =~ "2026-10-24 12:00:00.123"
      assert compact =~ "[info]"
      assert compact =~ "Phoenix.Logger"
      assert compact =~ "request_id=req-42"
      assert compact =~ "the redacted message"
      refute compact =~ "phoenix_endpoint_start"
      refute compact =~ "#PID<0.1.0>"
      refute compact =~ "logger.ex"
      # stored line untouched
      assert entry.line =~ "FULL docker-logs line"
    end

    test "falls back to the derived source label when module metadata is absent" do
      entry = %{
        time: {{2026, 10, 24}, {12, 0, 0, 0}},
        level: :warning,
        message: "warned",
        metadata: %{},
        source: "YtDlp",
        line: "x"
      }

      assert LogBuffer.format_line(entry, :compact) =~ "[warning] YtDlp | warned"
    end
  end
end
