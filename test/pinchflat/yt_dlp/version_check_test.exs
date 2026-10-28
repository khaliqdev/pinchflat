defmodule Pinchflat.YtDlp.VersionCheckTest do
  use Pinchflat.DataCase, async: true

  import Mox

  alias Pinchflat.YtDlp.VersionCheck

  setup :verify_on_exit!

  describe "latest_stable_version/0" do
    test "returns the stable tag from the GitHub release payload" do
      expect(HTTPClientMock, :get, fn url, headers, _opts ->
        assert url == "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
        assert {"accept", "application/vnd.github+json"} in headers

        # GitHub's API rejects requests without a User-Agent
        assert {"user-agent", user_agent} = Enum.find(headers, fn {name, _value} -> name == "user-agent" end)
        assert user_agent == VersionCheck.user_agent()
        assert user_agent =~ "re-Pinchflat/"

        {:ok, ~s({"tag_name": "2026.10.21", "name": "Latest"})}
      end)

      assert {:ok, "2026.10.21"} = VersionCheck.latest_stable_version()
    end

    test "trims whitespace from the tag" do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, ~s({"tag_name": " 2026.10.21 "})}
      end)

      assert {:ok, "2026.10.21"} = VersionCheck.latest_stable_version()
    end

    test "errors when GitHub is unreachable" do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:error, "HTTP request failed with status code 403: rate limited"}
      end)

      assert {:error, reason} = VersionCheck.latest_stable_version()
      assert reason =~ "could not reach GitHub"
      assert reason =~ "403"
    end

    test "errors on a malformed payload" do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, "<html>maintenance</html>"}
      end)

      assert {:error, "unexpected response from GitHub"} = VersionCheck.latest_stable_version()
    end

    test "errors on an empty tag" do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, ~s({"tag_name": ""})}
      end)

      assert {:error, "unexpected response from GitHub"} = VersionCheck.latest_stable_version()
    end
  end

  describe "version_state/2" do
    test "indeterminate while either side is unknown" do
      assert VersionCheck.version_state(nil, "2026.10.21") == :indeterminate
      assert VersionCheck.version_state("2026.10.21", nil) == :indeterminate
      assert VersionCheck.version_state(nil, nil) == :indeterminate
    end

    test "update_available when the latest stable is newer than installed" do
      assert VersionCheck.version_state("2026.09.01", "2026.10.21") == :update_available
      assert VersionCheck.version_state("2026.09.01", "2026.09.02") == :update_available
    end

    test "up_to_date when the versions match" do
      assert VersionCheck.version_state("2026.10.21", "2026.10.21") == :up_to_date
    end

    test "tolerates surrounding whitespace" do
      assert VersionCheck.version_state(" 2026.10.21 ", "2026.10.21") == :up_to_date
    end

    test "newer_installed when installed is ahead of stable (e.g. a nightly)" do
      assert VersionCheck.version_state("2026.10.22.232815", "2026.10.21") == :newer_installed
      assert VersionCheck.version_state("2026.10.21.232815", "2026.10.21") == :newer_installed
    end

    test "indeterminate when either version is not a date-style tag" do
      assert VersionCheck.version_state("latest", "2026.10.21") == :indeterminate
      assert VersionCheck.version_state("2026.10.21", "") == :indeterminate
    end
  end
end
