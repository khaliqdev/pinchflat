defmodule PinchflatWeb.Pages.DownloadsProgressLiveTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.DownloadProgress
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Pages.DownloadsProgressLive

  setup do
    DownloadProgress.reset!()

    on_exit(&DownloadProgress.reset!/0)
  end

  describe "render/1 when nothing is downloading" do
    test "renders nothing at all - no empty card box", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, DownloadsProgressLive, session: %{})

      refute html =~ "Downloading"
      refute html =~ "border-stroke"
    end
  end

  describe "render/1 with executing downloads" do
    test "shows the title, thumbnail, and media item link", %{conn: conn} do
      {source, media_item, _task, _job} = create_media_item_job()

      {:ok, _view, html} = live_isolated(conn, DownloadsProgressLive, session: %{})

      assert html =~ media_item.title
      assert html =~ "https://i.ytimg.com/vi/#{media_item.media_id}/mqdefault.jpg"
      assert html =~ ~p"/sources/#{source.id}/media/#{media_item}"
    end

    test "renders an indeterminate bar (and no 0%) when there is no progress row", %{conn: conn} do
      {_source, media_item, _task, _job} = create_media_item_job()

      {:ok, _view, html} = live_isolated(conn, DownloadsProgressLive, session: %{})

      assert html =~ "animate-pulse"
      refute html =~ "0%"
      refute html =~ "width:"
    end

    test "renders the percent bar and speed/ETA text from a seeded progress row", %{conn: conn} do
      {_source, media_item, _task, _job} = create_media_item_job()

      :ok =
        DownloadProgress.record_line(
          media_item.id,
          ~s({"downloaded_bytes": 524288, "total_bytes": 1048576, "_speed_str": "2.00MiB/s", "_eta_str": "00:30"})
        )

      {:ok, _view, html} = live_isolated(conn, DownloadsProgressLive, session: %{})

      assert html =~ "width: 50.0%"
      assert html =~ "50.0%"
      assert html =~ "2.00MiB/s"
      assert html =~ "ETA 00:30"
      refute html =~ "animate-pulse"
    end
  end

  describe "handle_info/2 for progress broadcasts" do
    test "updates the percent without changing the item set", %{conn: conn} do
      {source, media_item, _task, _job} = create_media_item_job()

      {:ok, view, html} = live_isolated(conn, DownloadsProgressLive, session: %{})

      assert html =~ "animate-pulse"

      PinchflatWeb.Endpoint.broadcast("download_progress", "progress", %{
        media_item_id: media_item.id,
        percent: 95.0,
        speed: "8.00MiB/s",
        eta: "00:02"
      })

      assert_eventually(fn -> assert render(view) =~ "width: 95.0%" end)

      updated_html = render(view)

      assert updated_html =~ "ETA 00:02"

      # The item set is untouched by progress ticks - same titles and links
      assert titles_in(html) == titles_in(updated_html)
      assert links_in(html, source.id) == links_in(updated_html, source.id)
    end

    test "ignores broadcasts for items that are not downloading", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job()

      {:ok, view, html} = live_isolated(conn, DownloadsProgressLive, session: %{})

      PinchflatWeb.Endpoint.broadcast("download_progress", "progress", %{
        media_item_id: 999_999,
        percent: 50.0,
        speed: "1.00MiB/s",
        eta: "00:10"
      })

      # Give the (ignored) broadcast a chance to land before re-rendering
      Process.sleep(100)

      updated_html = render(view)

      # Same rows as before, and no progress was merged in for the junk id
      assert titles_in(updated_html) == titles_in(html)
      refute updated_html =~ "width: 50.0%"
      refute updated_html =~ "1.00MiB/s"
    end

    test "does not crash on malformed payloads with missing keys", %{conn: conn} do
      {_source, media_item, _task, _job} = create_media_item_job()

      {:ok, view, _html} = live_isolated(conn, DownloadsProgressLive, session: %{})

      # Missing percent/speed/eta keys - the view must tolerate it rather
      # than raising a MatchError and tearing down the card
      PinchflatWeb.Endpoint.broadcast("download_progress", "progress", %{media_item_id: media_item.id})

      Process.sleep(100)

      updated_html = render(view)

      assert updated_html =~ media_item.title
      assert updated_html =~ "animate-pulse"
      refute updated_html =~ "width:"
    end
  end

  describe "handle_info/2 for job:state broadcasts" do
    test "drops the row once the job is no longer executing", %{conn: conn} do
      {_source, media_item, task, _job} = create_media_item_job()

      {:ok, view, html} = live_isolated(conn, DownloadsProgressLive, session: %{})
      assert html =~ media_item.title

      Oban.Job
      |> where([j], j.id == ^task.job_id)
      |> Repo.update_all(set: [state: "completed"])

      PinchflatWeb.Endpoint.broadcast("job:state", "change", nil)

      # The requery is debounced (@job_state_debounce_ms of 400ms); poll
      # past it until the row disappears
      assert_eventually(fn -> refute render(view) =~ media_item.title end)
    end
  end

  defp create_media_item_job(job_state \\ :executing) do
    source = source_fixture()
    media_item = media_item_fixture(source_id: source.id)
    {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)

    Oban.Job
    |> where([j], j.id == ^task.job_id)
    |> Repo.update_all(set: [state: to_string(job_state)])

    job = Repo.get!(Oban.Job, task.job_id)

    {source, media_item, task, job}
  end

  defp assert_eventually(fun, attempts_left \\ 20) do
    try do
      fun.()
      true
    rescue
      e in ExUnit.AssertionError ->
        if attempts_left <= 1 do
          reraise e, __STACKTRACE__
        else
          Process.sleep(50)
          assert_eventually(fun, attempts_left - 1)
        end
    end
  end

  defp titles_in(html) do
    ~r{>([^<]+)</a>}
    |> Regex.scan(html)
    |> Enum.map(fn [_, title] -> String.trim(title) end)
  end

  defp links_in(html, source_id) do
    ~r{href="(/sources/#{source_id}/media/[^"]+)"}
    |> Regex.scan(html)
    |> Enum.map(fn [_, link] -> link end)
  end
end
