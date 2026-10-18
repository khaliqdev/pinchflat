defmodule PinchflatWeb.Sources.MediaItemTableLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias PinchflatWeb.Sources.MediaItemTableLive

  setup do
    source = source_fixture()

    {:ok, source: source}
  end

  describe "initial rendering" do
    test "shows message when no records", %{conn: conn, source: source} do
      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))

      assert html =~ "Nothing Here!"
      refute html =~ "Showing"
    end

    test "shows records when present", %{conn: conn, source: source} do
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))

      assert html =~ "Showing"
      assert html =~ "Title"
      assert html =~ media_item.title
    end
  end

  describe "media_state" do
    test "shows pending media when pending", %{conn: conn, source: source} do
      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "pending"))

      assert html =~ pending_media_item.title
      refute html =~ downloaded_media_item.title
    end

    test "shows downloaded media when downloaded", %{conn: conn, source: source} do
      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      assert html =~ downloaded_media_item.title
      refute html =~ pending_media_item.title
    end

    test "shows records that aren't pending or downloaded when other", %{conn: conn} do
      media_profile = media_profile_fixture(shorts_behaviour: :exclude)
      source = source_fixture(media_profile_id: media_profile.id)

      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      other_media_item = media_item_fixture(source_id: source.id, media_filepath: nil, short_form_content: true)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "other"))

      assert html =~ other_media_item.title
      refute html =~ downloaded_media_item.title
      refute html =~ pending_media_item.title
    end

    test "shows 'Manually Ignored' column when other", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id, prevent_download: true, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "other"))

      assert html =~ "Download Prevented?"
    end
  end

  defp create_session(source, media_state \\ "pending") do
    %{"source_id" => source.id, "media_state" => media_state}
  end
  describe "media thumbnails" do
    test "renders a YouTube CDN thumb for pending items", %{conn: conn} do
      source = source_fixture()
      media_item_fixture(%{source_id: source.id, media_filepath: nil, media_id: "dQw4w9WgXcQ"})

      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "pending"))

      assert element(view, "img[src*='i.ytimg.com/vi/dQw4w9WgXcQ']") |> has_element?
    end

    test "renders a local thumb route for downloaded items with a stored thumbnail", %{conn: conn} do
      source = source_fixture()
      media_item =
        media_item_fixture(%{
          source_id: source.id,
          media_filepath: "/video/x.mp4",
          thumbnail_filepath: "/thumbs/x.jpg",
          media_id: "abc123"
        })

      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      assert element(view, "img[src='/media/#{media_item.uuid}/episode_image']") |> has_element?
    end

    test "prefers the YouTube thumb when a downloaded item has no stored thumbnail", %{conn: conn} do
      source = source_fixture()
      media_item_fixture(%{
        source_id: source.id,
        media_filepath: "/video/y.mp4",
        thumbnail_filepath: nil,
        media_id: "def456"
      })

      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      assert element(view, "img[src*='i.ytimg.com/vi/def456']") |> has_element?
    end
  end

end
