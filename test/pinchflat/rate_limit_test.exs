defmodule Pinchflat.RateLimitTest do
  use Pinchflat.DataCase

  alias Pinchflat.RateLimit

  setup do
    RateLimit.clear!()

    on_exit(&RateLimit.clear!/0)
  end

  describe "tripped?/1" do
    test "returns false when no cooldown has been set" do
      refute RateLimit.tripped?()
    end

    test "returns true while the cooldown is active" do
      RateLimit.trip!(15)
      now = DateTime.add(DateTime.utc_now(), 5 * 60)

      assert RateLimit.tripped?(now)
    end

    test "returns false once the cooldown has expired" do
      RateLimit.trip!(15)
      now = DateTime.add(DateTime.utc_now(), 16 * 60)

      refute RateLimit.tripped?(now)
    end
  end

  describe "seconds_remaining/1" do
    test "returns 0 when no cooldown is active" do
      assert RateLimit.seconds_remaining() == 0
    end

    test "returns the remaining seconds of the cooldown" do
      RateLimit.trip!(15)
      now = DateTime.add(DateTime.utc_now(), 5 * 60)

      assert_in_delta RateLimit.seconds_remaining(now), 600, 5
    end
  end

  describe "broadcasts" do
    test "tripping the cooldown broadcasts on the rate_limit topic" do
      PinchflatWeb.Endpoint.subscribe("rate_limit")

      RateLimit.trip!(15)

      assert_receive %{topic: "rate_limit", event: "change"}, 100
    end
  end
end
