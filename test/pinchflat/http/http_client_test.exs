defmodule Pinchflat.HTTP.HTTPClientTest do
  use Pinchflat.DataCase, async: true

  alias Pinchflat.HTTP.HTTPClient

  describe "format_error/1" do
    test "formats tuple reasons from :httpc without raising" do
      reason =
        {:failed_connect,
         [
           {:to_address, {~c"api.github.com", 443}},
           {:inet, [:inet], {:tls_alert, {:certificate_expired, "TLS client connection failed"}}}
         ]}

      message = HTTPClient.format_error(reason)

      assert is_binary(message)
      assert message =~ "failed_connect"
      assert message =~ "tls_alert"
    end

    test "formats plain reasons" do
      assert HTTPClient.format_error(:timeout) == ":timeout"
    end

    test "clamps very long reasons to a sane length" do
      message = HTTPClient.format_error({:oops, String.duplicate("x", 1_000)})

      assert String.length(message) <= 500
      assert message =~ "oops"
    end
  end
end
