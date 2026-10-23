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

    test "renders the shared confirm dialog and light-legible error output", %{conn: conn} do
      media_item_fixture(%{title: "Broken Thing", last_error: "ERROR: something broke"})

      conn = get(conn, ~p"/errors")
      html = html_response(conn, 200)

      assert html =~ "data-confirm-dialog-root"
      assert html =~ "data-confirm-dialog"
      refute html =~ "data-confirm=\""
      assert html =~ "name=\"_csrf_token\""
      assert html =~ "data-confirm-form"
      assert html =~ "text-body dark:text-bodydark1"
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

  describe "POST /errors/retry-selected" do
    test "retries only the selected pending errored items", %{conn: conn} do
      selected = media_item_fixture(%{title: "Selected", last_error: "boom", media_filepath: nil})
      unselected = media_item_fixture(%{title: "Unselected", last_error: "boom", media_filepath: nil})

      conn =
        post(conn, ~p"/errors/retry-selected", %{"selected_ids" => [Integer.to_string(selected.id)]})

      assert redirected_to(conn) == "/errors"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Retried 1 item(s)"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "skipped 0"

      assert Repo.reload!(selected).last_error == nil
      assert Repo.reload!(unselected).last_error == "boom"
      assert_enqueued worker: MediaDownloadWorker, args: %{"id" => selected.id}
      refute_enqueued worker: MediaDownloadWorker, args: %{"id" => unselected.id}
    end

    test "skips selected items that are ignored or already downloaded", %{conn: conn} do
      retryable = media_item_fixture(%{title: "Retryable", last_error: "boom", media_filepath: nil})
      ignored =
        media_item_fixture(%{title: "Ignored", last_error: "boom", prevent_download: true, media_filepath: nil})

      downloaded = media_item_fixture(%{title: "Downloaded", last_error: "boom"})

      conn =
        post(conn, ~p"/errors/retry-selected", %{
          "selected_ids" =>
            Enum.map([retryable, ignored, downloaded], fn item -> Integer.to_string(item.id) end)
        })

      assert redirected_to(conn) == "/errors"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Retried 1 item(s)"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "skipped 2"

      assert Repo.reload!(retryable).last_error == nil
      assert Repo.reload!(ignored).last_error == "boom"
      assert Repo.reload!(downloaded).last_error == "boom"
      assert_enqueued worker: MediaDownloadWorker, args: %{"id" => retryable.id}
    end

    test "only considers items on the current errored batch", %{conn: conn} do
      errored = media_item_fixture(%{title: "Errored", last_error: "boom", media_filepath: nil})
      fresh = media_item_fixture(%{title: "Fresh", media_filepath: nil})

      conn =
        post(conn, ~p"/errors/retry-selected", %{
          "selected_ids" => [Integer.to_string(fresh.id), Integer.to_string(errored.id)]
        })

      assert redirected_to(conn) == "/errors"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Retried 1 item(s)"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "skipped 1"

      assert_enqueued worker: MediaDownloadWorker, args: %{"id" => errored.id}
      refute_enqueued worker: MediaDownloadWorker, args: %{"id" => fresh.id}
    end

    test "scopes selection to the source filter", %{conn: conn} do
      item = media_item_fixture(%{title: "Filtered out", last_error: "boom", media_filepath: nil})
      other_source_item = media_item_fixture(%{title: "Other source", media_filepath: nil})

      conn =
        post(conn, ~p"/errors/retry-selected", %{
          "selected_ids" => [Integer.to_string(item.id)],
          "source_id" => Integer.to_string(other_source_item.source_id)
        })

      assert redirected_to(conn) == "/errors"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Retried 0 item(s)"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "skipped 1"

      assert Repo.reload!(item).last_error == "boom"
      refute_enqueued worker: MediaDownloadWorker
    end

    test "does nothing when no valid ids are given", %{conn: conn} do
      conn = post(conn, ~p"/errors/retry-selected", %{"selected_ids" => ["not-an-id"]})

      assert redirected_to(conn) == "/errors"
      refute Phoenix.Flash.get(conn.assigns.flash, :info)
      refute_enqueued worker: MediaDownloadWorker
    end
  end

end
