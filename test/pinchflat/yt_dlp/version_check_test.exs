defmodule Pinchflat.YtDlp.VersionCheckTest do
  use Pinchflat.DataCase, async: true

  import Mox

  alias Pinchflat.YtDlp.VersionCheck

  setup :verify_on_exit!

  describe "latest_stable_version/0" do
    test "returns the stable tag from the GitHub release payload" do
      expect(HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url == "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"

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

  describe "update_available?/2" do
    test "false while either side is unknown" do
      refute VersionCheck.update_available?(nil, "2026.10.21")
      refute VersionCheck.update_available?("2026.10.21", nil)
      refute VersionCheck.update_available?(nil, nil)
    end

    test "true only when the versions differ" do
      refute VersionCheck.update_available?("2026.10.21", "2026.10.21")
      assert VersionCheck.update_available?("2026.09.01", "2026.10.21")
    end

    test "tolerates surrounding whitespace" do
      refute VersionCheck.update_available?(" 2026.10.21 ", "2026.10.21")
    end
  end
end
