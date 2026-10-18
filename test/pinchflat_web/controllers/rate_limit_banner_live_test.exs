defmodule Pinchflat.Pages.RateLimitBannerLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.RateLimit
  alias Pinchflat.Pages.RateLimitBannerLive

  setup do
    RateLimit.clear!()

    on_exit(&RateLimit.clear!/0)

    :ok
  end

  describe "render/1" do
    test "renders nothing when no cooldown is active", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, RateLimitBannerLive)

      refute html =~ "rate limit active"
    end

    test "renders the banner inside its own padded container when tripped", %{conn: conn} do
      RateLimit.trip!(15)

      {:ok, _view, html} = live_isolated(conn, RateLimitBannerLive)

      assert html =~ "YouTube rate limit active"
      # The banner carries its own container padding so an inactive banner
      # leaves zero space above the header
      assert html =~ "pt-4"
    end
  end
end
