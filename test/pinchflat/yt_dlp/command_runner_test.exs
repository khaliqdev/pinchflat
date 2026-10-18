defmodule Pinchflat.YtDlp.CommandRunnerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.RateLimit
  alias Pinchflat.Utils.FilesystemUtils

  alias Pinchflat.YtDlp.CommandRunner, as: Runner

  @original_executable Application.compile_env(:pinchflat, :yt_dlp_executable)
  @media_url "https://www.youtube.com/watch?v=-LHXuyzpex0"

  setup do
    on_exit(&reset_executable/0)
  end

  describe "run/4" do
    test "returns the output and status when the command succeeds" do
      assert {:ok, _output} = Runner.run(@media_url, :foo, [], "")
    end

    test "considers a 101 exit code as being successful" do
      wrap_executable("/app/test/support/scripts/yt-dlp-mocks/101_exit_code.sh", fn ->
        assert {:ok, _output} = Runner.run(@media_url, :foo, [], "")
      end)
    end

    test "includes the media url as the first argument" do
      assert {:ok, output} = Runner.run(@media_url, :foo, [:ignore_errors], "")

      assert String.contains?(output, "#{@media_url} --ignore-errors")
    end

    test "automatically includes the --print-to-file flag" do
      assert {:ok, output} = Runner.run(@media_url, :foo, [], "%(id)s")

      assert String.contains?(output, "--print-to-file %(id)s /tmp/")
    end

    test "returns the output and status when the command fails" do
      wrap_executable("/bin/false", fn ->
        assert {:error, "", 1} = Runner.run(@media_url, :foo, [], "")
      end)
    end

    test "optionally lets you specify an output_filepath" do
      assert {:ok, output} = Runner.run(@media_url, :foo, [], "%(id)s", output_filepath: "/tmp/yt-dlp-output.json")

      assert String.contains?(output, "--print-to-file %(id)s /tmp/yt-dlp-output.json")
    end
  end

  describe "run/4 when testing external file options" do
    setup do
      base_dir = Application.get_env(:pinchflat, :extras_directory)
      cookie_file = Path.join(base_dir, "cookies.txt")
      yt_dlp_file = Path.join([base_dir, "yt-dlp-configs", "main.txt"])

      {:ok, cookie_file: cookie_file, yt_dlp_file: yt_dlp_file}
    end

    test "includes cookie options when cookies.txt exists and enabled", %{cookie_file: cookie_file} do
      FilesystemUtils.write_p!(cookie_file, "cookie data")

      assert {:ok, output} = Runner.run(@media_url, :foo, [], "", use_cookies: true)

      assert String.contains?(output, "--cookies #{cookie_file}")
    end

    test "doesn't include cookie options when cookies.txt exists but disabled", %{cookie_file: cookie_file} do
      FilesystemUtils.write_p!(cookie_file, "cookie data")

      assert {:ok, output} = Runner.run(@media_url, :foo, [], "", use_cookies: false)

      refute String.contains?(output, "--cookies #{cookie_file}")
    end

    test "doesn't include cookie options when cookies.txt blank", %{cookie_file: cookie_file} do
      FilesystemUtils.write_p!(cookie_file, " \n \n ")

      assert {:ok, output} = Runner.run(@media_url, :foo, [], "", use_cookies: true)

      refute String.contains?(output, "--cookies")
      refute String.contains?(output, cookie_file)
    end

    test "doesn't include cookie options when cookies.txt doesn't exist", %{cookie_file: cookie_file} do
      File.rm(cookie_file)

      assert {:ok, output} = Runner.run(@media_url, :foo, [], "")

      refute String.contains?(output, "--cookies")
      refute String.contains?(output, cookie_file)

      # Cleanup
      FilesystemUtils.write_p!(cookie_file, "")
    end
  end

  describe "run/4 when testing rate limit options" do
    test "includes sleep interval options by default" do
      Settings.set(extractor_sleep_interval_seconds: 5)

      assert {:ok, output} = Runner.run(@media_url, :foo, [], "")

      assert String.contains?(output, "--sleep-interval")
      assert String.contains?(output, "--sleep-requests")
      assert String.contains?(output, "--sleep-subtitles")
    end

    test "doesn't include sleep interval options when skip_sleep_interval is true" do
      assert {:ok, output} = Runner.run(@media_url, :foo, [], "", skip_sleep_interval: true)

      refute String.contains?(output, "--sleep-interval")
      refute String.contains?(output, "--sleep-requests")
      refute String.contains?(output, "--sleep-subtitles")
    end

    test "doesn't include sleep interval options when extractor_sleep_interval_seconds is 0" do
      Settings.set(extractor_sleep_interval_seconds: 0)

      assert {:ok, output} = Runner.run(@media_url, :foo, [], "")

      refute String.contains?(output, "--sleep-interval")
      refute String.contains?(output, "--sleep-requests")
      refute String.contains?(output, "--sleep-subtitles")
    end

    test "includes limit_rate option when specified" do
      Settings.set(download_throughput_limit: "100K")

      assert {:ok, output} = Runner.run(@media_url, :foo, [], "")

      assert String.contains?(output, "--limit-rate 100K")
    end

    test "doesn't include limit_rate option when download_throughput_limit is nil" do
      Settings.set(download_throughput_limit: nil)

      assert {:ok, output} = Runner.run(@media_url, :foo, [], "")

      refute String.contains?(output, "--limit-rate")
    end
  end

  describe "run/4 when testing global options" do
    test "creates windows-safe filenames" do
      assert {:ok, output} = Runner.run(@media_url, :foo, [], "")

      assert String.contains?(output, "--windows-filenames")
    end

    test "runs quietly" do
      assert {:ok, output} = Runner.run(@media_url, :foo, [], "")

      assert String.contains?(output, "--quiet")
    end

    test "sets the cache directory" do
      assert {:ok, output} = Runner.run(@media_url, :foo, [], "")

      assert String.contains?(output, "--cache-dir /tmp/test/tmpfiles/yt-dlp-cache")
    end
  end

  describe "run/4 when testing misc options" do
    test "includes --restrict-filenames when enabled" do
      Settings.set(restrict_filenames: true)

      assert {:ok, output} = Runner.run(@media_url, :foo, [], "")

      assert String.contains?(output, "--restrict-filenames")
    end

    test "doesn't include --restrict-filenames when disabled" do
      Settings.set(restrict_filenames: false)

      assert {:ok, output} = Runner.run(@media_url, :foo, [], "")

      refute String.contains?(output, "--restrict-filenames")
    end
  end

  describe "version/0" do
    test "adds the version arg" do
      assert {:ok, output} = Runner.version()

      assert String.contains?(output, "--version")
    end
  end

  describe "run/4 tmpfile cleanup" do
    test "deletes the generated output file after reading it" do
      tmp_dir = Application.get_env(:pinchflat, :tmpfile_directory)
      before_count = count_json_files(tmp_dir)

      assert {:ok, _} = Runner.run(@media_url, :foo, [], "")
      Process.sleep(50)

      assert count_json_files(tmp_dir) == before_count
    end

    test "keeps caller-supplied output files" do
      filepath = FilesystemUtils.generate_metadata_tmpfile(:json)

      assert {:ok, _} = Runner.run(@media_url, :foo, [], "", output_filepath: filepath)
      Process.sleep(50)

      assert File.exists?(filepath)
      File.rm(filepath)
    end

    defp count_json_files(dir) do
      dir
      |> File.ls!()
      |> Enum.count(&String.ends_with?(&1, ".json"))
    end
  end

  describe "update/0" do
    test "adds the update arg" do
      assert {:ok, output} = Runner.update()

      assert String.contains?(output, "--update")
    end

    test "considers a 100 exit code as being successful" do
      wrap_executable("/app/test/support/scripts/yt-dlp-mocks/100_exit_code.sh", fn ->
        assert {:ok, output} = Runner.update()

        assert String.contains?(output, "Restart to complete update")
      end)
    end
  end

  describe "run/5 with a :progress callback" do
    @progress_emitter Path.join([File.cwd!(), "/test/support/scripts/yt-dlp-mocks/progress_emitter.sh"])
    @progress_emitter_429 Path.join([File.cwd!(), "/test/support/scripts/yt-dlp-mocks/progress_emitter_429.sh"])
    @progress_emitter_fragment Path.join([File.cwd!(), "/test/support/scripts/yt-dlp-mocks/progress_emitter_fragment.sh"])

    test "forwards every emitted line to the callback in order and returns the print-to-file contents" do
      wrap_executable(@progress_emitter, fn ->
        {result, lines} = run_collecting_lines(@media_url, :download, [:no_progress, :no_simulate], "after_move:%()j")

        assert {:ok, output} = result
        assert String.contains?(output, "Finished Video")

        assert [junk, json1, json2, json3, json4, warning] = lines

        # The >4096-byte junk line is reassembled from :noeol fragments and
        # does not corrupt the lines that follow it
        assert byte_size(junk) > 4096
        assert json1 =~ "total_bytes"
        assert json2 =~ "total_bytes_estimate"
        refute json3 =~ "total_bytes"
        assert json4 =~ "45.32MiB"
        assert warning =~ "WARNING"

        # Merged stderr ordering is preserved relative to stdout lines
        assert Enum.count(lines) == 6
      end)
    end

    test "flushes a trailing :noeol fragment on exit so it reaches the callback and the error output" do
      RateLimit.clear!()
      on_exit(&RateLimit.clear!/0)

      wrap_executable(@progress_emitter_fragment, fn ->
        {result, lines} = run_collecting_lines(@media_url, :download, [:no_progress, :no_simulate], "after_move:%()j")

        assert {:error, output, 1} = result

        # The unterminated stderr line is forwarded to the callback as the
        # final line AND kept in the accumulated output (429 detection
        # depends on it - System.cmd never drops trailing bytes)
        assert [_json_line, fragment] = lines
        assert fragment =~ "HTTP Error 429"
        assert String.contains?(output, "HTTP Error 429")

        assert RateLimit.tripped?()
      end)
    end

    test "returns error output (with stderr) and trips the rate limit on a streaming 429" do
      RateLimit.clear!()
      on_exit(&RateLimit.clear!/0)

      wrap_executable(@progress_emitter_429, fn ->
        {result, lines} = run_collecting_lines(@media_url, :download, [:no_progress, :no_simulate], "after_move:%()j")

        assert {:error, output, 1} = result
        assert String.contains?(output, "HTTP Error 429")

        # The stdout progress line and the merged stderr error line
        assert [progress_line, error_line] = lines
        assert progress_line =~ "downloaded_bytes"
        assert error_line =~ "HTTP Error 429"

        assert RateLimit.tripped?()
      end)
    end

    test "strips :no_progress, adds the progress flags, and keeps the URL as the first argument" do
      assert {:ok, output} = Runner.run(@media_url, :download, [:no_progress], "%(id)s", progress: fn _line -> :ok end)

      refute String.contains?(output, "--no-progress")
      assert String.contains?(output, "--progress")
      assert String.contains?(output, "--newline")
      assert String.contains?(output, "--progress-template download:%(progress.{status,downloaded_bytes,total_bytes,total_bytes_estimate,_speed_str,_eta_str})j")
      assert String.contains?(output, "--progress-delta 1")

      # Arg order mirrors the System.cmd invocation (URL first, like the
      # "#{@media_url} --ignore-errors" assertions in the run/4 describes)
      assert String.contains?(output, "#{@media_url} --print-to-file")
    end

    test "a raising callback does not abort the port loop" do
      wrap_executable(@progress_emitter, fn ->
        result =
          Runner.run(@media_url, :download, [:no_progress], "after_move:%()j", progress: fn line ->
            send(self(), {:progress_line, line})
            raise "callback exploded"
          end)

        assert {:ok, output} = result
        assert String.contains?(output, "Finished Video")

        # Every emitted line was still observed even though the callback
        # raised on each one
        assert length(receive_all()) == 6
      end)
    end

    test "actions without :progress keep using the System.cmd path unchanged" do
      # repeater.sh (the default test executable) echoes its args to the
      # print-to-file path - this is the untouched non-streaming contract
      assert {:ok, output} = Runner.run(@media_url, :download, [:no_progress], "%(id)s")

      assert String.contains?(output, "--no-progress")
      refute String.contains?(output, "--progress-template")
    end
  end

  # Runs the command with a callback that mirrors every line back to the
  # test process as a message, returning {run_result, lines_in_order}
  defp run_collecting_lines(url, action, command_opts, output_template) do
    result = Runner.run(url, action, command_opts, output_template, progress: fn line -> send(self(), {:progress_line, line}) end)

    lines = Enum.map(receive_all(), fn {:progress_line, line} -> line end)

    {result, lines}
  end

  defp receive_all do
    receive_all([])
  end

  defp receive_all(acc) do
    receive do
      {:progress_line, line} -> receive_all([{:progress_line, line} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp wrap_executable(new_executable, fun) do
    Application.put_env(:pinchflat, :yt_dlp_executable, new_executable)
    fun.()
    reset_executable()
  end

  def reset_executable do
    Application.put_env(:pinchflat, :yt_dlp_executable, @original_executable)
  end
end
