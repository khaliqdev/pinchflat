defmodule Pinchflat.YtDlp.RateLimitDetectionTest do
  use Pinchflat.DataCase

  alias Pinchflat.RateLimit
  alias Pinchflat.YtDlp.CommandRunner, as: Runner

  @media_url "https://www.youtube.com/watch?v=-LHXuyzpex0"

  setup do
    RateLimit.clear!()

    on_exit(&RateLimit.clear!/0)
  end

  test "trips the global cooldown when yt-dlp output contains a 429 error" do
    refute RateLimit.tripped?()

    with_mock_executable("/app/test/support/scripts/yt-dlp-mocks/429_rate_limited.sh", fn ->
      assert {:error, output, 1} = Runner.run(@media_url, :foo, [], "")

      assert String.contains?(output, "HTTP Error 429")
      assert RateLimit.tripped?()
    end)
  end

  test "does not trip the cooldown on unrelated errors" do
    with_mock_executable("/bin/false", fn ->
      assert {:error, _, 1} = Runner.run(@media_url, :foo, [], "")

      refute RateLimit.tripped?()
    end)
  end

  defp with_mock_executable(new_executable, fun) do
    original = Application.fetch_env!(:pinchflat, :yt_dlp_executable)
    Application.put_env(:pinchflat, :yt_dlp_executable, new_executable)

    try do
      fun.()
    after
      Application.put_env(:pinchflat, :yt_dlp_executable, original)
    end
  end
end
