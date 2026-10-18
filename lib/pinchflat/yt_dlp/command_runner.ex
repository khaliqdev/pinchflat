defmodule Pinchflat.YtDlp.CommandRunner do
  @moduledoc """
  Runs yt-dlp commands using the `System.cmd/3` function

  When `addl_opts` carries a `:progress` callback (arity 1), the command is
  streamed through a port instead: every complete stdout line is handed to
  the callback as it arrives (merged stderr included) while still being
  accumulated for the final return value. See `YtDlpCommandRunner`'s
  moduledoc for the convention.
  """

  require Logger

  alias Pinchflat.RateLimit
  alias Pinchflat.Settings
  alias Pinchflat.Utils.CliUtils
  alias Pinchflat.Utils.NumberUtils
  alias Pinchflat.YtDlp.YtDlpCommandRunner
  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils

  @behaviour YtDlpCommandRunner

  # Verified against yt-dlp 2026.08.19: works alongside --quiet, emits one
  # JSON object per line with --newline, and absent/NA fields simply omit or
  # null the key. _speed_str/_eta_str arrive humanized (" Unknown B/s").
  @progress_template "download:%(progress.{status,downloaded_bytes,total_bytes,total_bytes_estimate,_speed_str,_eta_str})j"

  @doc """
  Runs a yt-dlp command and returns the string output. Saves the output to
  a file and then returns its contents because yt-dlp will return warnings
  to stdout even if the command is successful, but these will break JSON parsing.

  Additional Opts:
    - :output_filepath - the path to save the output to. If not provided, a temporary
      file will be created and used. Useful for if you need a reference to the file
      for a file watcher.
    - :use_cookies - if true, will add a cookie file to the command options. Will not
      attach a cookie file if the user hasn't set one up.
    - :skip_sleep_interval - if true, will not add the sleep interval options to the command.
      Usually only used for commands that would be UI-blocking
    - :progress - if set to an arity-1 function, the command is streamed through a
      port and every complete output line is passed to the function as it arrives.
      Adds progress-specific yt-dlp flags (and strips :no_progress) so the
      callback actually receives lines

  Returns {:ok, binary()} | {:error, output, status}.
  """
  @impl YtDlpCommandRunner
  def run(url, action_name, command_opts, output_template, addl_opts \\ []) do
    throttle_if_rate_limited!(addl_opts)

    Logger.debug("Running yt-dlp command for action: #{action_name}")

    output_filepath = generate_output_filepath(addl_opts)
    caller_supplied_filepath = Keyword.has_key?(addl_opts, :output_filepath)
    progress_callback = Keyword.get(addl_opts, :progress)
    print_to_file_opts = [{:print_to_file, output_template}, output_filepath]
    user_configured_opts = cookie_file_options(addl_opts) ++ rate_limit_options(addl_opts) ++ misc_options()

    command_opts = maybe_strip_no_progress(command_opts, progress_callback)
    progress_opts = maybe_progress_options(progress_callback)

    # These must stay in exactly this order, hence why I'm giving it its own variable.
    all_opts = command_opts ++ print_to_file_opts ++ user_configured_opts ++ global_options() ++ progress_opts

    case execute_command(all_opts, url, progress_callback) do
      # yt-dlp exit codes:
      #   0 = Everything is successful
      #   100 = yt-dlp must restart for update to complete
      #   101 = Download cancelled by --max-downloads etc
      #     2 = Error in user-provided options
      #     1 = Any other error
      {_, status} when status in [0, 101] ->
        result = File.read(output_filepath)

        # Tmpfiles accumulate one-per-command forever otherwise (thousands per
        # month on an active library). Caller-supplied paths are left alone
        # since the file watcher needs them to persist.
        if not caller_supplied_filepath, do: File.rm(output_filepath)

        result

      {output, status} ->
        maybe_trip_rate_limit(output)

        # Clean up even (especially) on error - the file may be partial but is
        # still captured in full in the returned output
        if not caller_supplied_filepath, do: File.rm(output_filepath)

        {:error, output, status}
    end
  end

  @doc """
  Returns the version of yt-dlp as a string

  Returns {:ok, binary()} | {:error, binary()}
  """
  @impl YtDlpCommandRunner
  def version do
    command = backend_executable()

    case CliUtils.wrap_cmd(command, ["--version"]) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, _} ->
        {:error, output}
    end
  end

  @doc """
  Updates yt-dlp to the latest version

  Returns {:ok, binary()} | {:error, binary()}
  """
  @impl YtDlpCommandRunner
  def update do
    command = backend_executable()

    case CliUtils.wrap_cmd(command, ["--update"]) do
      # 100 = the update completed but yt-dlp must restart to finish applying it.
      # The binary on disk is already updated at this point.
      {output, status} when status in [0, 100] ->
        {:ok, String.trim(output)}

      {output, _} ->
        {:error, output}
    end
  end

  # If we're not streaming, this is the untouched System.cmd path that every
  # non-download action (and every caller that passes no :progress) keeps
  # using - simulate/thumbnail/metadata flows must degrade silently.
  defp execute_command(all_opts, url, nil) do
    formatted_command_opts = [url] ++ CliUtils.parse_options(all_opts)

    CliUtils.wrap_cmd(backend_executable(), formatted_command_opts, stderr_to_stdout: true)
  end

  defp execute_command(all_opts, url, progress_callback) do
    stream_command_output(all_opts, url, progress_callback)
  end

  # Streams output through the same cmd_wrapper.sh (forked before the wrapper
  # silences its own fds, so the child keeps our stdout pipe and the
  # stdin-EOF SIGKILL semantics are preserved). :stderr_to_stdout matches the
  # System.cmd path so 429 detection and saved error messages keep working.
  # Args are built identically to the System.cmd path (URL first) so the two
  # invocations stay byte-identical.
  defp stream_command_output(all_opts, url, progress_callback) do
    wrapper_command = Path.join(:code.priv_dir(:pinchflat), "cmd_wrapper.sh")
    formatted_command_opts = [url] ++ CliUtils.parse_options(all_opts)
    args = [backend_executable() | formatted_command_opts]
    tmpfile_dir = Application.get_env(:pinchflat, :tmpfile_directory)

    Logger.info("[command_wrapper]: #{backend_executable()} called with: #{Enum.join(args, " ")}")

    port =
      Port.open({:spawn_executable, wrapper_command}, [
        :use_stdio,
        :stderr_to_stdout,
        :exit_status,
        :binary,
        {:line, 4096},
        {:args, args},
        {:cd, tmpfile_dir}
      ])

    receive_lines(port, progress_callback, [], "")
  end

  defp receive_lines(port, progress_callback, acc, fragment) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        full_line = fragment <> line

        safe_progress_callback(progress_callback, full_line)

        receive_lines(port, progress_callback, [full_line | acc], "")

      {^port, {:data, {:noeol, part}}} ->
        # Merged warnings can exceed the 4096-byte line buffer; reassemble
        # or every subsequent JSON line would be corrupted
        receive_lines(port, progress_callback, acc, fragment <> part)

      {^port, {:exit_status, status}} ->
        # The port has already closed itself on child exit (Port.close here
        # would raise) - we only needed to drain its messages in order.
        # The final partial line (if the child exited without a trailing
        # newline) is flushed asynchronously AFTER exit_status, so drain any
        # straggler data before building the output - otherwise neither the
        # callback nor the accumulated output (429 detection, saved error
        # messages) would see it, diverging from System.cmd's byte-complete
        # output.
        {acc, fragment} = drain_after_exit(port, acc, fragment, progress_callback)
        acc = flush_fragment(acc, fragment, progress_callback)

        output =
          acc
          |> Enum.reverse()
          |> Enum.join("\n")

        log_level = if status == 0, do: :debug, else: :error
        Logger.log(log_level, "[command_wrapper]: streamed command exited: #{status} with: #{output}")

        {output, status}
    end
  end

  # The child is dead by the time we get here, so anything still in flight is
  # already buffered in the port - it lands within microseconds of the exit
  # status (verified against the port directly). The idle timeout only pads
  # each streaming command by 100ms, which is noise next to a download.
  defp drain_after_exit(port, acc, fragment, progress_callback) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        full_line = fragment <> line

        safe_progress_callback(progress_callback, full_line)

        drain_after_exit(port, [full_line | acc], "", progress_callback)

      {^port, {:data, {:noeol, part}}} ->
        drain_after_exit(port, acc, fragment <> part, progress_callback)
    after
      100 ->
        {acc, fragment}
    end
  end

  defp flush_fragment(acc, "", _progress_callback), do: acc

  defp flush_fragment(acc, fragment, progress_callback) do
    safe_progress_callback(progress_callback, fragment)

    [fragment | acc]
  end

  # A raising progress callback must never kill a live download (same stance
  # as the file follower's poison-line handling)
  defp safe_progress_callback(progress_callback, line) do
    try do
      progress_callback.(line)
    rescue
      e ->
        Logger.error("""
        Progress callback raised on line - skipping it:
        #{Exception.format(:error, e, __STACKTRACE__)}
        """)
    end
  end

  # DownloadOptionBuilder sets :no_progress for downloads (and we don't rely
  # on yt-dlp last-flag-wins semantics to defeat it)
  defp maybe_strip_no_progress(command_opts, nil), do: command_opts

  defp maybe_strip_no_progress(command_opts, _progress_callback) do
    Enum.reject(command_opts, &(&1 == :no_progress))
  end

  defp maybe_progress_options(nil), do: []

  defp maybe_progress_options(_progress_callback) do
    [:progress, :newline, {:progress_template, @progress_template}, {:progress_delta, "1"}]
  end

  # If YouTube has flagged us (HTTP 429 anywhere in yt-dlp output), trip a global
  # cooldown so subsequent yt-dlp work waits instead of deepening the block.
  # UI-blocking commands (skip_sleep_interval) never wait.
  defp throttle_if_rate_limited!(addl_opts) do
    if RateLimit.tripped?() && !Keyword.get(addl_opts, :skip_sleep_interval, false) do
      seconds = RateLimit.seconds_remaining()

      Logger.warning("Rate limit cooldown active - delaying yt-dlp command by #{seconds}s")

      Process.sleep(seconds * 1000)
    end
  end

  defp maybe_trip_rate_limit(output) do
    if String.contains?(to_string(output), "HTTP Error 429"), do: RateLimit.trip!()
  end

  defp generate_output_filepath(addl_opts) do
    case Keyword.get(addl_opts, :output_filepath) do
      nil -> FSUtils.generate_metadata_tmpfile(:json)
      path -> path
    end
  end

  defp global_options do
    [
      :windows_filenames,
      :quiet,
      cache_dir: Path.join(Application.get_env(:pinchflat, :tmpfile_directory), "yt-dlp-cache")
    ]
  end

  defp cookie_file_options(addl_opts) do
    case Keyword.get(addl_opts, :use_cookies) do
      true -> add_cookie_file()
      _ -> []
    end
  end

  defp add_cookie_file do
    base_dir = Application.get_env(:pinchflat, :extras_directory)
    filename_options_map = %{cookies: "cookies.txt"}

    Enum.reduce(filename_options_map, [], fn {opt_name, filename}, acc ->
      filepath = Path.join(base_dir, filename)

      if FSUtils.exists_and_nonempty?(filepath) do
        [{opt_name, filepath} | acc]
      else
        acc
      end
    end)
  end

  defp rate_limit_options(addl_opts) do
    throughput_limit = Settings.get!(:download_throughput_limit)
    sleep_interval_opts = sleep_interval_opts(addl_opts)
    throughput_option = if throughput_limit, do: [limit_rate: throughput_limit], else: []

    throughput_option ++ sleep_interval_opts
  end

  defp sleep_interval_opts(addl_opts) do
    sleep_interval = Settings.get!(:extractor_sleep_interval_seconds)

    if sleep_interval <= 0 || Keyword.get(addl_opts, :skip_sleep_interval) do
      []
    else
      [
        sleep_requests: NumberUtils.add_jitter(sleep_interval),
        sleep_interval: NumberUtils.add_jitter(sleep_interval),
        sleep_subtitles: NumberUtils.add_jitter(sleep_interval)
      ]
    end
  end

  defp misc_options do
    if Settings.get!(:restrict_filenames), do: [:restrict_filenames], else: []
  end

  defp backend_executable do
    Application.get_env(:pinchflat, :yt_dlp_executable)
  end
end
