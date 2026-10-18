defmodule Pinchflat.YtDlp.YtDlpCommandRunner do
  @moduledoc """
  A behaviour for running CLI commands against a downloader backend (yt-dlp).

  Used so we can implement Mox for testing without actually running the
  yt-dlp command.

  ## Progress streaming convention

  `run/5`'s `addl_opts` may carry a `:progress` callback (arity 1). When
  present, the runner streams yt-dlp's stdout line-by-line, invoking
  `callback.(line)` with each complete line as the download progresses
  (merged stderr included), and still returns the same
  `{:ok, binary()} | {:error, binary(), integer()}` contract when the
  command finishes. Only the `:download` action attaches a callback today;
  every other action takes the plain `System.cmd` path.

  For Mox users: the callback arrives as a plain function under
  `addl_opts[:progress]`, so test doubles can invoke it inside `expect/verify`
  bodies to simulate progress lines without spawning a port:

      expect(YtDlpRunnerMock, :run, fn _url, :download, _opts, _ot, addl ->
        if callback = Keyword.get(addl_opts, :progress) do
          callback.(~s({"downloaded_bytes": 50, "total_bytes": 100}))
        end

        {:ok, "{}"}
      end)
  """

  @callback run(binary(), atom(), keyword(), binary()) :: {:ok, binary()} | {:error, binary(), integer()}
  @callback run(binary(), atom(), keyword(), binary(), keyword()) :: {:ok, binary()} | {:error, binary(), integer()}
  @callback version() :: {:ok, binary()} | {:error, binary()}
  @callback update() :: {:ok, binary()} | {:error, binary()}
end
