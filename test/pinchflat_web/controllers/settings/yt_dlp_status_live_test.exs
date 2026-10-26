defmodule PinchflatWeb.Settings.YtDlpStatusLiveTest do
  use PinchflatWeb.ConnCase

  import Mox
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Pinchflat.Settings
  alias Pinchflat.Settings.YtDlpStatusLive

  setup do
    Settings.set(yt_dlp_version: "2026.09.01")
    :ok
  end

  describe "render/1" do
    test "shows the installed version, auto-update mode, and buttons", %{conn: conn} do
      {:ok, view, html} = live_isolated(conn, YtDlpStatusLive)

      assert html =~ "2026.09.01"
      assert html =~ "not checked"
      assert html =~ "Check for updates"
      assert html =~ "Update now"
      assert has_element?(view, "button[phx-click=check]")
      assert has_element?(view, "button[phx-click=update]")
    end
  end

  describe "handle_event check" do
    test "a newer release shows the update-available badge", %{conn: conn} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, ~s({"tag_name": "2026.10.21"})}
      end)

      {:ok, view, _html} = live_isolated(conn, YtDlpStatusLive)

      assert render_click(view, :check) =~ "2026.10.21"
      assert render(view) =~ "update available"
    end

    test "the same release shows the up-to-date badge", %{conn: conn} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, ~s({"tag_name": "2026.09.01"})}
      end)

      {:ok, view, _html} = live_isolated(conn, YtDlpStatusLive)
      render_click(view, :check)

      assert render(view) =~ "up to date"
    end

    test "a failed check shows the error inline", %{conn: conn} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:error, "HTTP request failed with status code 403: rate limited"}
      end)

      {:ok, view, _html} = live_isolated(conn, YtDlpStatusLive)

      assert render_click(view, :check) =~ "Check failed"
    end
  end

  describe "handle_event update" do
    test "queues the worker and reports progress", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, YtDlpStatusLive)

      render_click(view, :update)

      assert render(view) =~ "Update queued"
    end

    test "a completed job reports the new version", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, YtDlpStatusLive)
      render_click(view, :update)

      # The enqueued update job is the only fresh UpdateWorker row
      from(j in Oban.Job, where: j.worker == "Pinchflat.YtDlp.UpdateWorker")
      |> Pinchflat.Repo.update_all(set: [state: "completed"])

      Settings.set(yt_dlp_version: "2026.10.21")

      send(view.pid, :poll)

      assert render(view) =~ "Updated yt-dlp 2026.09.01"
      assert render(view) =~ "2026.10.21"
    end
  end
end
