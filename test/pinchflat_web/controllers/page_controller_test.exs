defmodule PinchflatWeb.PageControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings

  describe "GET / when testing onboarding" do
    test "sets the onboarding setting to true when onboarding", %{conn: conn} do
      _conn = get(conn, ~p"/")
      assert Settings.get!(:onboarding)
    end

    test "displays the onboarding page when onboarding is forced", %{conn: conn} do
      Settings.set(onboarding: false)

      conn = get(conn, ~p"/?onboarding=1")
      assert html_response(conn, 200) =~ "Welcome to re:Pinchflat"
    end

    test "sets the onboarding setting to false if you pass the corrent query param", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert Settings.get!(:onboarding)

      _conn = get(conn, ~p"/?onboarding=0")
      refute Settings.get!(:onboarding)
    end

    test "displays the home page when not onboarding", %{conn: conn} do
      Settings.set(onboarding: false)

      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "MENU"
    end
  end

  describe "GET / YouTube-on-TV home layout" do
    setup do
      Settings.set(onboarding: false)
      :ok
    end

    test "renders the hero with the newest download and the recents shelf", %{conn: conn} do
      source = source_fixture(custom_name: "TV Test Channel")

      media_item_fixture(
        source_id: source.id,
        title: "Hero Video Title",
        media_downloaded_at: DateTime.utc_now()
      )

      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      assert html =~ "Latest download"
      assert html =~ "Hero Video Title"
      assert html =~ "TV Test Channel"
      assert html =~ "Recently downloaded"
    end

    test "renders a per-source shelf with health badges", %{conn: conn} do
      source = source_fixture(custom_name: "Shelf Channel")
      media_item_fixture(source_id: source.id, media_downloaded_at: DateTime.utc_now())
      media_item_fixture(source_id: source.id, last_error: "boom")

      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      assert html =~ "Shelf Channel"
      assert html =~ "1 failed"
      assert html =~ "Check now"
    end

    test "renders the empty-library hero when nothing is downloaded", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert html_response(conn, 200) =~ "Add a source"
    end
  end
end
