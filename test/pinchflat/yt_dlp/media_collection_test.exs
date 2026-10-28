defmodule Pinchflat.YtDlp.MediaCollectionTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.YtDlp.Media
  alias Pinchflat.YtDlp.MediaCollection

  @channel_url "https://www.youtube.com/c/PinchflatTestChannel"

  describe "get_media_attributes_for_collection/2" do
    test "returns a list of video attributes with no blank elements" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        {:ok, source_attributes_return_fixture() <> "\n\n"}
      end)

      assert {:ok, [%Media{media_id: "video1"}, %Media{media_id: "video2"}, %Media{media_id: "video3"}]} =
               MediaCollection.get_media_attributes_for_collection(@channel_url)
    end

    test "passes the expected default args" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, opts, ot, _addl_opts ->
        assert opts == [:simulate, :skip_download, :ignore_no_formats_error, :no_warnings]
        assert ot == Media.indexing_output_template()

        {:ok, ""}
      end)

      assert {:ok, _} = MediaCollection.get_media_attributes_for_collection(@channel_url)
    end

    test "returns the error straight through when the command fails" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        {:error, "Big issue", 1}
      end)

      assert {:error, "Big issue", 1} = MediaCollection.get_media_attributes_for_collection(@channel_url)
    end

    test "passes long additional command options" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        assert :foo in opts

        {:ok, ""}
      end)

      assert {:ok, _} = MediaCollection.get_media_attributes_for_collection(@channel_url, [:foo])
    end

    test "passes additional args to runner" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        assert [{:output_filepath, filepath} | _] = addl_opts
        assert {:use_cookies, false} in addl_opts
        assert String.ends_with?(filepath, ".json")

        {:ok, ""}
      end)

      assert {:ok, _} = MediaCollection.get_media_attributes_for_collection(@channel_url)
    end

    test "supports an optional file_listener_handler that gets passed a filename" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        {:ok, ""}
      end)

      current_self = self()

      handler = fn filename ->
        send(current_self, {:handler, filename})
      end

      assert {:ok, _} =
               MediaCollection.get_media_attributes_for_collection(@channel_url, [], file_listener_handler: handler)

      assert_receive {:handler, filename}
      assert String.ends_with?(filename, ".json")
    end

    test "gracefully handles partially failed responses" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        {:ok, "INVALID\n\n" <> source_attributes_return_fixture() <> "\nINVALID\n"}
      end)

      assert {:ok, [%Media{media_id: "video1"}, %Media{media_id: "video2"}, %Media{media_id: "video3"}]} =
               MediaCollection.get_media_attributes_for_collection(@channel_url)
    end
  end

  describe "get_source_details/1" do
    test "returns a map with data on success" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl_opts ->
        Phoenix.json_library().encode(%{
          channel: "PinchflatTestChannel",
          channel_id: "UCQH2",
          playlist_id: "PLQH2",
          playlist_title: "PinchflatTestChannel - Videos"
        })
      end)

      assert {:ok, res} = MediaCollection.get_source_details(@channel_url)

      assert %{
               channel_id: "UCQH2",
               channel_name: "PinchflatTestChannel",
               playlist_id: "PLQH2",
               playlist_name: "PinchflatTestChannel - Videos"
             } = res
    end

    test "passes the expected args to the runner" do
      expect(YtDlpRunnerMock, :run, fn @channel_url, :get_source_details, opts, ot, _addl_opts ->
        assert opts == [:simulate, :skip_download, :ignore_no_formats_error, playlist_end: 1]
        assert ot == "%(.{channel,channel_id,playlist_id,playlist_title,filename})j"

        {:ok, "{}"}
      end)

      assert {:ok, _} = MediaCollection.get_source_details(@channel_url)
    end

    test "passes custom args to the runner" do
      expect(YtDlpRunnerMock, :run, fn @channel_url, :get_source_details, opts, _ot, _addl_opts ->
        assert {:foo, :bar} in opts

        {:ok, "{}"}
      end)

      assert {:ok, _} = MediaCollection.get_source_details(@channel_url, foo: :bar)
    end

    test "passes additional args to the runner" do
      expect(YtDlpRunnerMock, :run, fn @channel_url, :get_source_details, _opts, _ot, addl_opts ->
        assert {:use_cookies, true} in addl_opts

        {:ok, "{}"}
      end)

      assert {:ok, _} = MediaCollection.get_source_details(@channel_url, [], use_cookies: true)
    end

    test "returns an error if the runner returns an error" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl_opts -> {:error, "Big issue", 1} end)

      assert {:error, "Big issue", 1} = MediaCollection.get_source_details(@channel_url)
    end

    test "returns an error if the output is not JSON" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl_opts -> {:ok, "Not JSON"} end)

      assert {:error, "Error decoding JSON response"} = MediaCollection.get_source_details(@channel_url)
    end
  end

  describe "get_source_metadata/1" do
    test "returns a map with data on success" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        Phoenix.json_library().encode(%{channel: "PinchflatTestChannel"})
      end)

      assert {:ok, res} = MediaCollection.get_source_metadata(@channel_url, playlist_items: 0)

      assert %{"channel" => "PinchflatTestChannel"} = res
    end

    test "decodes concatenated multi-document output, keeping the last (playlist) document" do
      # --print-to-file APPENDS every template evaluation to one file, so a run
      # with an entry range produces the video-stage docs followed by the
      # playlist blob. The playlist document is the last top-level object.
      doc1 = ~s({"id": "vid1", "autonumber": 0, "resolution": null})
      doc2 = ~s({"id": "UCB123", "playlist_count": 3, "entries": [{"id": "vid1"}]})

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        {:ok, doc1 <> "\n" <> doc2}
      end)

      assert {:ok, %{"playlist_count" => 3, "entries" => [%{"id" => "vid1"}]}} =
               MediaCollection.get_source_metadata(@channel_url, playlist_items: 1)
    end

    test "prefers the tab-expanded media listing over the channel-wrapper playlist" do
      # A channel URL writes the expanded listing AND the channel wrapper (whose
      # entries are the channel's tabs) into the same file. The wrapper is not
      # what a source indexes - the expanded listing is.
      expanded =
        ~s({"id": "UCB123-videos", "playlist_count": 2, "entries": [{"id": "vid1", "url": "https://www.youtube.com/watch?v=vid1"}, {"id": "vid2", "url": "https://www.youtube.com/watch?v=vid2"}]})

      wrapper =
        ~s({"id": "UCB123", "playlist_count": 3, "entries": [{"_type": "playlist", "title": "Videos", "url": "https://www.youtube.com/@test/videos"}, {"_type": "playlist", "title": "Live", "url": "https://www.youtube.com/@test/streams"}, {"_type": "playlist", "title": "Shorts", "url": "https://www.youtube.com/@test/shorts"}]})

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        {:ok, expanded <> "\n" <> wrapper}
      end)

      assert {:ok, %{"playlist_count" => 2, "entries" => [%{"id" => "vid1"}, %{"id" => "vid2"}]}} =
               MediaCollection.get_source_metadata(@channel_url, playlist_items: 1)
    end

    test "merges the tab-expanded listings of a multi-document channel, deduped by entry id" do
      # A multi-tab channel writes one expanded listing PER TAB (videos, shorts,
      # live) plus the channel wrapper. Keeping only the largest listing would
      # hide the media living in the other tabs - eg: a shorts-only profile
      # scanning to ~0 because its shorts are in their own document
      videos =
        ~s({"id": "UCB123-videos", "playlist_count": 2, "entries": [{"id": "vid1"}, {"id": "vid2"}]})

      shorts =
        ~s({"id": "UCB123-shorts", "playlist_count": 1, "entries": [{"id": "vid1"}, {"id": "short1"}]})

      wrapper =
        ~s({"id": "UCB123", "playlist_count": 3, "entries": [{"_type": "playlist", "id": "UCB123-videos"}, {"_type": "playlist", "id": "UCB123-shorts"}]})

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        {:ok, videos <> "\n" <> shorts <> "\n" <> wrapper}
      end)

      assert {:ok, merged} = MediaCollection.get_source_metadata(@channel_url, playlist_items: 1)

      # per-tab counts summed (2 + 1); the wrapper contributes no media entries
      assert merged["playlist_count"] == 3
      # vid1 appears in both tabs but only once in the merged listing
      assert Enum.map(merged["entries"], & &1["id"]) == ["vid1", "vid2", "short1"]
    end

    test "drops playlist-shaped entries (playlist _type or own entries) from the merged listing" do
      listing =
        ~s({"id": "UCB123-videos", "entries": [{"id": "vid1"}, {"_type": "playlist", "id": "UCB123", "url": "https://www.youtube.com/@test"}, {"id": "UCB123-nested", "entries": [{"id": "inner"}]}, {"id": "vid2"}]})

      # The merge (and its playlist-entry dropping) only runs for
      # multi-document output; the second doc is a channel wrapper, not a
      # media listing, so the first doc is the only listing in the merge
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        {:ok, listing <> "\n" <> ~s({"_type": "playlist", "id": "UCB123", "url": "https://www.youtube.com/@test"})}
      end)

      assert {:ok, merged} = MediaCollection.get_source_metadata(@channel_url, playlist_items: 1)

      # no playlist_count anywhere: the combined count falls back to the
      # merged listing's own media entries
      assert merged["playlist_count"] == 2
      assert Enum.map(merged["entries"], & &1["id"]) == ["vid1", "vid2"]
    end

    test "skips an undecodable document and returns the best remaining one" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        {:ok, ~s({"id": "vid1", "autonumber": 0}) <> "\n" <> "{\"broken\": "}
      end)

      assert {:ok, %{"id" => "vid1"}} =
               MediaCollection.get_source_metadata(@channel_url, playlist_items: 1)
    end

    test "passes the expected args to the backend runner" do
      expect(YtDlpRunnerMock, :run, fn @channel_url, :get_source_metadata, opts, ot, _addl_opts ->
        assert opts == [:skip_download, playlist_items: 0]
        assert ot == "playlist:%()j"

        {:ok, "{}"}
      end)

      assert {:ok, _} = MediaCollection.get_source_metadata(@channel_url, playlist_items: 0)
    end

    test "passes additional args to the runner" do
      expect(YtDlpRunnerMock, :run, fn @channel_url, :get_source_metadata, _opts, _ot, addl_opts ->
        assert {:use_cookies, true} in addl_opts

        {:ok, "{}"}
      end)

      assert {:ok, _} = MediaCollection.get_source_metadata(@channel_url, [playlist_items: 0], use_cookies: true)
    end

    test "passes custom args to the runner" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, opts, _ot, _addl_opts ->
        assert opts == [:skip_download, playlist_items: 1, real_opt: :yup]

        {:ok, "{}"}
      end)

      assert {:ok, _} = MediaCollection.get_source_metadata(@channel_url, playlist_items: 1, real_opt: :yup)
    end

    test "blows up if you pass addl opts but don't pass playlist items" do
      assert_raise KeyError, fn ->
        MediaCollection.get_source_metadata(@channel_url, real_opt: :yup)
      end
    end

    test "returns an error if the runner returns an error" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        {:error, "Big issue", 1}
      end)

      assert {:error, "Big issue", 1} = MediaCollection.get_source_metadata(@channel_url, playlist_items: 0)
    end

    test "returns an error if the output is not JSON" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts -> {:ok, "Not JSON"} end)

      assert {:error, %Jason.DecodeError{}} = MediaCollection.get_source_metadata(@channel_url, playlist_items: 0)
    end
  end
end
