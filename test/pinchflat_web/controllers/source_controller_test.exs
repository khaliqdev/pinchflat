defmodule PinchflatWeb.SourceControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Media.FileSyncingWorker
  alias Pinchflat.Sources.SourceDeletionWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker

  setup do
    media_profile = media_profile_fixture()
    Settings.set(onboarding: false)

    {
      :ok,
      %{
        create_attrs: %{
          media_profile_id: media_profile.id,
          collection_type: "channel",
          original_url: "https://www.youtube.com/source/abc123"
        },
        update_attrs: %{
          original_url: "https://www.youtube.com/source/321xyz"
        },
        invalid_attrs: %{original_url: nil, media_profile_id: nil}
      }
    }
  end

  describe "index" do
    # Most of the tests are in `index_table_list_test.exs`
    test "returns 200", %{conn: conn} do
      conn = get(conn, ~p"/sources")
      assert html_response(conn, 200) =~ "Sources"
    end
  end

  describe "new source" do
    test "renders form", %{conn: conn} do
      conn = get(conn, ~p"/sources/new")
      assert html_response(conn, 200) =~ "New Source"
    end

    test "renders correct layout when onboarding", %{conn: conn} do
      Settings.set(onboarding: true)
      conn = get(conn, ~p"/sources/new")

      refute html_response(conn, 200) =~ "MENU"
    end

    test "preloads some attributes when using a template", %{conn: conn} do
      source = source_fixture(custom_name: "My first source", download_cutoff_date: "2021-01-01")

      conn = get(conn, ~p"/sources/new", %{"template_id" => source.id})
      assert html_response(conn, 200) =~ "New Source"
      assert html_response(conn, 200) =~ "2021-01-01"
      refute html_response(conn, 200) =~ source.custom_name
    end
  end

  describe "create source" do
    test "redirects to show when data is valid", %{conn: conn, create_attrs: create_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)
      conn = post(conn, ~p"/sources", source: create_attrs)

      assert %{id: id} = redirected_params(conn)
      assert redirected_to(conn) == ~p"/sources/#{id}"

      conn = get(conn, ~p"/sources/#{id}")
      assert html_response(conn, 200) =~ "Source"
    end

    test "renders errors when data is invalid", %{conn: conn, invalid_attrs: invalid_attrs} do
      conn = post(conn, ~p"/sources", source: invalid_attrs)
      assert html_response(conn, 200) =~ "New Source"
    end

    test "redirects to onboarding when onboarding", %{conn: conn, create_attrs: create_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)

      Settings.set(onboarding: true)
      conn = post(conn, ~p"/sources", source: create_attrs)

      assert redirected_to(conn) == ~p"/?onboarding=1"
    end

    test "renders correct layout on error when onboarding", %{conn: conn, invalid_attrs: invalid_attrs} do
      Settings.set(onboarding: true)
      conn = post(conn, ~p"/sources", source: invalid_attrs)

      refute html_response(conn, 200) =~ "MENU"
    end
  end

  describe "edit source" do
    setup [:create_source]

    test "renders form for editing chosen source", %{conn: conn, source: source} do
      conn = get(conn, ~p"/sources/#{source}/edit")
      assert html_response(conn, 200) =~ "Editing \"#{source.custom_name}\""
    end
  end

  describe "update source" do
    setup [:create_source]

    test "redirects when data is valid", %{conn: conn, source: source, update_attrs: update_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)

      conn = put(conn, ~p"/sources/#{source}", source: update_attrs)
      assert redirected_to(conn) == ~p"/sources/#{source}"

      conn = get(conn, ~p"/sources/#{source}")
      assert html_response(conn, 200) =~ "https://www.youtube.com/source/321xyz"
    end

    test "renders errors when data is invalid", %{
      conn: conn,
      source: source,
      invalid_attrs: invalid_attrs
    } do
      conn = put(conn, ~p"/sources/#{source}", source: invalid_attrs)
      assert html_response(conn, 200) =~ "Editing \"#{source.custom_name}\""
    end
  end

  describe "delete source in all cases" do
    setup [:create_source]

    test "redirects to the sources page", %{conn: conn, source: source} do
      conn = delete(conn, ~p"/sources/#{source}")
      assert redirected_to(conn) == ~p"/sources"
    end

    test "sets marked_for_deletion_at", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}")
      assert Repo.reload!(source).marked_for_deletion_at
    end
  end

  describe "delete source when just deleting the records" do
    setup [:create_source]

    test "enqueues a job without the delete_files arg", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}")

      assert [%{args: %{"delete_files" => false}}] = all_enqueued(worker: SourceDeletionWorker)
    end
  end

  describe "delete source when deleting the records and files" do
    setup [:create_source]

    test "enqueues a job without the delete_files arg", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}?delete_files=true")

      assert [%{args: %{"delete_files" => true}}] = all_enqueued(worker: SourceDeletionWorker)
    end
  end

  describe "force_download_pending" do
    test "enqueues pending download tasks", %{conn: conn} do
      source = source_fixture()
      _media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{source.id}/force_download_pending")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_download_pending")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "force_redownload" do
    test "enqueues re-download tasks", %{conn: conn} do
      source = source_fixture()
      _media_item = media_item_fixture(source_id: source.id, media_downloaded_at: now())

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{source.id}/force_redownload")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_redownload")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "force_index" do
    test "forces an index", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: MediaCollectionIndexingWorker)
      post(conn, ~p"/sources/#{source.id}/force_index")
      assert [_] = all_enqueued(worker: MediaCollectionIndexingWorker)
    end

    test "forces an index even if one wouldn't normally run", %{conn: conn} do
      source = source_fixture(index_frequency_minutes: 0, last_indexed_at: DateTime.utc_now())

      post(conn, ~p"/sources/#{source.id}/force_index")
      assert [job] = all_enqueued(worker: MediaCollectionIndexingWorker)
      assert job.args == %{"id" => source.id, "force" => true}
    end

    test "deletes pending indexing tasks", %{conn: conn} do
      source = source_fixture()
      {:ok, task} = MediaCollectionIndexingWorker.kickoff_with_task(source)
      job = Repo.preload(task, :job).job

      assert job.state == "available"
      post(conn, ~p"/sources/#{source.id}/force_index")
      assert Repo.reload!(job).state == "cancelled"
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_index")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "force_metadata_refresh" do
    test "forces a metadata refresh", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: SourceMetadataStorageWorker)
      post(conn, ~p"/sources/#{source.id}/force_metadata_refresh")
      assert [_] = all_enqueued(worker: SourceMetadataStorageWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_metadata_refresh")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "sync_files_on_disk" do
    test "forces a file sync", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: FileSyncingWorker)
      post(conn, ~p"/sources/#{source.id}/sync_files_on_disk")
      assert [_] = all_enqueued(worker: FileSyncingWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/sync_files_on_disk")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "POST /sources/scan" do
    setup do
      # The scanner runs its yt-dlp call inside a Task so it can enforce a hard
      # timeout - the mock gets invoked from that other process, so
      # expectations must be global (safe: these tests are not async)
      set_mox_global()

      # The timeout test overrides the scan timeout; reset it no matter how the
      # test ends so the leak can't reach other tests
      on_exit(fn -> Application.put_env(:pinchflat, :source_scan_timeout_ms, nil) end)

      :ok
    end

    test "returns the preview-scan estimate as JSON", %{conn: conn, create_attrs: create_attrs} do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        {:ok,
         Phoenix.json_library().encode!(%{
           "playlist_count" => 3,
           "entries" => [
             %{
               "id" => "one",
               "title" => "One",
               "duration" => 60.0,
               "original_url" => "https://www.youtube.com/watch?v=one"
             }
           ]
         })}
      end)

      conn = post(conn, ~p"/sources/scan", source: create_attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["total_found"] == 3
      assert data["estimated_downloads"] == 1
      assert data["analyzed_entries"] == 1
      assert is_list(data["breakdown"])
    end

    test "returns field errors as 422 without calling yt-dlp", %{conn: conn} do
      # No Mox expectation on purpose: an unexpected runner call fails the test
      conn =
        post(conn, ~p"/sources/scan", source: %{"original_url" => "https://www.youtube.com/watch?v=abc123"})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["original_url"] == ["must be a channel or playlist URL"]
    end

    test "wraps yt-dlp failures as a scan-failed error", %{conn: conn, create_attrs: create_attrs} do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        {:error, "ERROR: something broke", 1}
      end)

      conn = post(conn, ~p"/sources/scan", source: create_attrs)

      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "Scan failed:"
      assert error =~ "something broke"
    end

    test "surfaces the hard timeout as 'channel too large for preview'", %{
      conn: conn,
      create_attrs: create_attrs
    } do
      # Generous headroom (100ms) so the spawned task reliably reaches the mock
      # before the yield expires - then the 500ms sleep guarantees the timeout
      Application.put_env(:pinchflat, :source_scan_timeout_ms, 100)

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        Process.sleep(500)
        {:ok, "{}"}
      end)

      conn = post(conn, ~p"/sources/scan", source: create_attrs)

      assert %{"error" => error} = json_response(conn, 408)
      assert error =~ "Channel too large for preview"
      assert error =~ "timed out"
    end

    test "renders the preview-scan control with CSRF wiring on the new form", %{conn: conn} do
      conn = get(conn, ~p"/sources/new")
      html = html_response(conn, 200)

      assert html =~ "Preview scan"
      assert html =~ "data-preview-scan-button"
      # The scan JS posts with an x-csrf-token header read from this meta tag.
      # Phoenix.ConnTest marks test conns to skip CSRF enforcement
      # (build_conn/0), so the token check itself can't be exercised over the
      # endpoint - the markup is the assertable half, same approach as the
      # errors-console tests
      assert html =~ ~s(name="csrf-token")
    end

    test "renders the preview-scan control on the edit form", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source}/edit")

      assert html_response(conn, 200) =~ "data-preview-scan-button"
    end
  end

  defp create_source(_) do
    source = source_fixture()
    media_item = media_item_with_attachments(%{source_id: source.id})

    %{source: source, media_item: media_item}
  end

  defp runner_function_mock(_url, :get_source_details, _opts, _ot, _addl) do
    {
      :ok,
      Phoenix.json_library().encode!(%{
        channel: "some channel name",
        channel_id: "some_channel_id_#{:rand.uniform(1_000_000)}",
        playlist_id: "some_playlist_id_#{:rand.uniform(1_000_000)}",
        playlist_title: "some playlist name"
      })
    }
  end
  describe "check_now/2" do
    test "kicks off a forced indexing job and redirects back to the source", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/check_now")

      assert redirected_to(conn) == "/sources/#{source.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Indexing started"

      assert_enqueued worker: MediaCollectionIndexingWorker, args: %{"force" => true, "id" => source.id}
    end

    test "404s when the source does not exist", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn ->
        post(conn, ~p"/sources/99999999/check_now")
      end
    end
  end

end
