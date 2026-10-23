defmodule Pinchflat.Sources.SourceScannerTest do
  use Pinchflat.DataCase

  import Mox
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources.Source
  alias Pinchflat.Sources.SourceScanner

  # The scanner runs its yt-dlp call inside a Task so it can enforce a hard
  # timeout - the mock gets invoked from that other process, so expectations
  # must be global (safe: these tests are not async)
  setup :set_mox_global

  # Shapes like a real --flat-playlist response: playlist_count is the true
  # listing size, and entries carry only what flat extraction provides
  # (title/duration/live_status can all be missing - the count math treats
  # missing data as "included", matching how the real index resolves it).
  defp scan_metadata do
    %{
      "playlist_count" => 6,
      "entries" => [
        %{
          "id" => "vid1",
          "title" => "Regular video",
          "duration" => 600.0,
          "live_status" => "not_live",
          "original_url" => "https://www.youtube.com/watch?v=vid1"
        },
        %{
          "id" => "vid2",
          "title" => "A short",
          "duration" => 45.0,
          "aspect_ratio" => 0.56,
          "original_url" => "https://www.youtube.com/shorts/vid2"
        },
        %{
          "id" => "vid3",
          "title" => "Stream VOD",
          "duration" => 3600.0,
          "live_status" => "was_live",
          "original_url" => "https://www.youtube.com/watch?v=vid3"
        },
        %{
          "id" => "vid4",
          "title" => "Oldie",
          "duration" => 600.0,
          "upload_date" => "20100101",
          "original_url" => "https://www.youtube.com/watch?v=vid4"
        },
        %{
          "id" => "vid5",
          "title" => "Uninteresting",
          "duration" => 600.0,
          "original_url" => "https://www.youtube.com/watch?v=vid5"
        },
        # Flat entries can lack fields entirely - no title, no duration
        %{"id" => "vid6", "original_url" => "https://www.youtube.com/watch?v=vid6"}
      ]
    }
  end

  defp expect_scan(metadata \\ scan_metadata()) do
    expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
      {:ok, Phoenix.json_library().encode!(metadata)}
    end)
  end

  defp scan_source(attrs \\ %{}) do
    source_fixture(Enum.into(attrs, %{original_url: "https://www.youtube.com/@somechannel"}))
  end

  defp removed_for(result, label) do
    step = Enum.find(result.breakdown, &(&1.label == label))

    step && step.removed
  end

  describe "scan/2" do
    test "returns the estimate and breakdown with no filters applied" do
      source = scan_source()
      expect_scan()

      assert {:ok, result} = SourceScanner.scan(source)

      assert result.total_found == 6
      assert result.analyzed_entries == 6
      assert result.estimated_downloads == 6
      # cutoff, title filter, shorts, livestreams, duration - no cap step
      # without a download_count and no disabled step with downloads on
      assert Enum.all?(result.breakdown, &(&1.removed == 0))

      assert Enum.map(result.breakdown, & &1.label) == [
               "download cutoff date",
               "title filter regex",
               "shorts",
               "livestreams",
               "min/max duration"
             ]
    end

    test "makes one flat listing call with the expected args" do
      source = scan_source(cookie_behaviour: :all_operations)

      expect(YtDlpRunnerMock, :run, fn url, :get_source_metadata, opts, ot, addl_opts ->
        assert url == source.original_url
        assert opts == [:skip_download, :flat_playlist, playlist_items: "1-10000"]
        assert ot == "playlist:%()j"
        # No :skip_sleep_interval - a scan inherits the 429 cooldown
        assert addl_opts == [use_cookies: true]

        {:ok, Phoenix.json_library().encode!(scan_metadata())}
      end)

      assert {:ok, _} = SourceScanner.scan(source)
    end

    test "does not request cookies for :disabled sources" do
      source = scan_source(cookie_behaviour: :disabled)

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, addl_opts ->
        assert addl_opts == [use_cookies: false]

        {:ok, Phoenix.json_library().encode!(scan_metadata())}
      end)

      assert {:ok, _} = SourceScanner.scan(source)
    end

    test "uses cookies for :when_needed sources, since a scan is indexing-class" do
      source = scan_source(cookie_behaviour: :when_needed)

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, addl_opts ->
        assert addl_opts == [use_cookies: true]

        {:ok, Phoenix.json_library().encode!(scan_metadata())}
      end)

      assert {:ok, _} = SourceScanner.scan(source)
    end

    test "applies the title filter regex, dropping titleless entries like the SQL does" do
      source = scan_source(title_filter_regex: "Regular")
      expect_scan()

      assert {:ok, result} = SourceScanner.scan(source)

      assert result.estimated_downloads == 1
      assert removed_for(result, "title filter regex") == 5
    end

    test "removes shorts when the profile excludes them" do
      profile = media_profile_fixture(shorts_behaviour: :exclude)
      source = scan_source(%{media_profile_id: profile.id})
      expect_scan()

      assert {:ok, result} = SourceScanner.scan(source)

      assert result.estimated_downloads == 5
      assert removed_for(result, "shorts") == 1
      assert removed_for(result, "livestreams") == 0
    end

    test "removes livestreams when the profile excludes them" do
      profile = media_profile_fixture(livestream_behaviour: :exclude)
      source = scan_source(%{media_profile_id: profile.id})
      expect_scan()

      assert {:ok, result} = SourceScanner.scan(source)

      assert result.estimated_downloads == 5
      assert removed_for(result, "shorts") == 0
      assert removed_for(result, "livestreams") == 1
    end

    test "keeps the union when shorts and livestreams are both :only" do
      profile = media_profile_fixture(shorts_behaviour: :only, livestream_behaviour: :only)
      source = scan_source(%{media_profile_id: profile.id})
      expect_scan()

      assert {:ok, result} = SourceScanner.scan(source)

      # only the short (vid2) and the stream VOD (vid3) survive
      assert result.estimated_downloads == 2
      # doubly-removed entries are attributed to the shorts step
      assert removed_for(result, "shorts") == 4
      assert removed_for(result, "livestreams") == 0
    end

    test "removes both kinds when the profile excludes both" do
      profile = media_profile_fixture(shorts_behaviour: :exclude, livestream_behaviour: :exclude)
      source = scan_source(%{media_profile_id: profile.id})
      expect_scan()

      assert {:ok, result} = SourceScanner.scan(source)

      # vid1, vid4, vid5 and the flag-less vid6 survive
      assert result.estimated_downloads == 4
      assert removed_for(result, "shorts") == 2
      assert removed_for(result, "livestreams") == 0
    end

    test "applies the minimum duration, failing duration-less entries" do
      source = scan_source(min_duration_seconds: 700)
      expect_scan()

      assert {:ok, result} = SourceScanner.scan(source)

      # only the stream VOD (3600s) survives
      assert result.estimated_downloads == 1
      assert removed_for(result, "min/max duration") == 5
    end

    test "applies the maximum duration" do
      source = scan_source(max_duration_seconds: 300)
      expect_scan()

      assert {:ok, result} = SourceScanner.scan(source)

      # only the short (45s) survives
      assert result.estimated_downloads == 1
      assert removed_for(result, "min/max duration") == 5
    end

    test "applies the download cutoff date" do
      source = scan_source(download_cutoff_date: ~D[2020-01-01])
      expect_scan()

      assert {:ok, result} = SourceScanner.scan(source)

      # the 2010 upload drops; entries without upload dates count as included
      assert result.estimated_downloads == 5
      assert removed_for(result, "download cutoff date") == 1
    end

    test "applies the download_count cap as the last step" do
      source = scan_source()
      expect_scan()

      assert {:ok, result} = SourceScanner.scan(source, download_count: 2)

      assert result.estimated_downloads == 2
      assert removed_for(result, "download count cap") == 4
    end

    test "reports zero when downloads are disabled" do
      source = scan_source(download_media: false)
      expect_scan()

      assert {:ok, result} = SourceScanner.scan(source)

      assert result.estimated_downloads == 0
      assert removed_for(result, "downloads disabled") == 6
    end

    test "falls back to the playlist total when no entries came back" do
      source = scan_source()
      expect_scan(%{"playlist_count" => 3000, "entries" => []})

      assert {:ok, result} = SourceScanner.scan(source)

      assert result.total_found == 3000
      assert result.analyzed_entries == 0
      assert result.estimated_downloads == 3000
      assert Enum.all?(result.breakdown, &(&1.removed == 0))
    end

    test "caps the entryless fallback at the download_count" do
      source = scan_source()
      expect_scan(%{"playlist_count" => 3000, "entries" => []})

      assert {:ok, result} = SourceScanner.scan(source, download_count: 50)

      assert result.estimated_downloads == 50
    end

    test "returns :timeout when the listing outlasts the hard timeout" do
      source = scan_source()

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        Process.sleep(500)

        {:ok, Phoenix.json_library().encode!(scan_metadata())}
      end)

      # Generous headroom (100ms) so the spawned task reliably reaches the mock
      # before the yield expires - then the 500ms sleep guarantees the timeout
      assert {:error, :timeout} = SourceScanner.scan(source, timeout_ms: 100)
    end

    test "wraps runner errors with the last line of output" do
      source = scan_source()

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        {:error, "WARNING: ignoring something\nERROR: HTTP Error 429", 1}
      end)

      assert {:error, {:scan_failed, "ERROR: HTTP Error 429"}} = SourceScanner.scan(source)
    end

    test "wraps unparseable output" do
      source = scan_source()

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        {:ok, "not json"}
      end)

      assert {:error, {:scan_failed, "could not parse yt-dlp output"}} = SourceScanner.scan(source)
    end

    test "rejects a regex Elixir's PCRE engine refuses (no yt-dlp traffic)" do
      profile = media_profile_fixture()

      # Built directly (not via the changeset) to simulate a regex that passes
      # SQLite's regexp_like validation but not Elixir's compiler
      source = %Source{
        original_url: "https://www.youtube.com/@somechannel",
        media_profile_id: profile.id,
        title_filter_regex: "("
      }

      assert {:error, {:invalid, errors}} = SourceScanner.scan(source)

      assert errors.title_filter_regex == ["is invalid"]
    end

    test "rejects a source whose media profile does not exist" do
      source = %Source{original_url: "https://www.youtube.com/@somechannel", media_profile_id: 987_654_321}

      assert {:error, {:invalid, errors}} = SourceScanner.scan(source)

      assert errors.media_profile_id == ["does not exist"]
    end
  end

  describe "scan_from_params/2" do
    test "scans form params without saving anything" do
      profile = media_profile_fixture()
      expect_scan()

      assert {:ok, result} =
               SourceScanner.scan_from_params(%{
                 "original_url" => "https://www.youtube.com/@somechannel",
                 "media_profile_id" => Integer.to_string(profile.id),
                 "title_filter_regex" => "",
                 "download_cutoff_date" => ""
               })

      assert result.total_found == 6
      assert result.estimated_downloads == 6
      # blank strings are dropped, so no title filter or cutoff was applied
      assert removed_for(result, "title filter regex") == 0
      assert removed_for(result, "download cutoff date") == 0
      assert Repo.aggregate(Source, :count) == 0
    end

    test "returns field errors for a video URL without any yt-dlp traffic" do
      profile = media_profile_fixture()

      assert {:error, {:invalid, errors}} =
               SourceScanner.scan_from_params(%{
                 "original_url" => "https://www.youtube.com/watch?v=abc123",
                 "media_profile_id" => Integer.to_string(profile.id)
               })

      assert errors.original_url == ["must be a channel or playlist URL"]
    end

    test "returns field errors when the media profile is missing" do
      assert {:error, {:invalid, errors}} =
               SourceScanner.scan_from_params(%{"original_url" => "https://www.youtube.com/@somechannel"})

      assert errors.media_profile_id == ["can't be blank"]
    end
  end

  describe "timeout_ms/0" do
    setup do
      on_exit(fn -> Application.put_env(:pinchflat, :source_scan_timeout_ms, nil) end)

      :ok
    end

    test "defaults to the 90s hard timeout" do
      assert SourceScanner.timeout_ms() == 90_000
    end

    test "is overridable via application env" do
      Application.put_env(:pinchflat, :source_scan_timeout_ms, 1_234)

      assert SourceScanner.timeout_ms() == 1_234
    end
  end
end
