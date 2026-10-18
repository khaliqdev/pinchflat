defmodule PinchflatWeb.MediaErrorControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Downloading.MediaDownloadWorker

  import Pinchflat.MediaFixtures

  describe "GET /errors" do
    test "lists media items with errors", %{conn: conn} do
      media_item_fixture(%{title: "Broken Thing", last_error: "ERROR: something broke"})

      conn = get(conn, ~p"/errors")

      assert html_response(conn, 200) =~ "Broken Thing"
      assert html_response(conn, 200) =~ "ERROR: something broke"
    end

    test "filters by source", %{conn: conn} do
      mine = media_item_fixture(%{title: "Mine Broke", last_error: "mine error"})
      _other = media_item_fixture(%{title: "Other Broke", last_error: "other error"})

      conn = get(conn, ~p"/errors?source_id=#{mine.source_id}")

      assert html_response(conn, 200) =~ "Mine Broke"
      refute html_response(conn, 200) =~ "Other Broke"
    end

    test "renders empty state", %{conn: conn} do
      conn = get(conn, ~p"/errors")

      assert html_response(conn, 200) =~ "No errors recorded"
    end
  end
  describe "POST /errors/retry" do
    test "retries pending errored items and skips ignored ones", %{conn: conn} do
      retryable = media_item_fixture(%{title: "Retryable", last_error: "boom", media_filepath: nil})
      skipped =
        media_item_fixture(%{title: "Skipped", last_error: "boom", prevent_download: true, media_filepath: nil})


      conn = post(conn, ~p"/errors/retry")

      assert redirected_to(conn) == "/errors"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Retried 1 item(s)"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "skipped 1"

      assert Repo.reload!(retryable).last_error == nil
      assert Repo.reload!(skipped).last_error == "boom"
      assert_enqueued worker: MediaDownloadWorker, args: %{"id" => retryable.id}
    end
  end

end
