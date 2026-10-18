defmodule Pinchflat.Media do
  @moduledoc """
  The Media context.
  """

  import Ecto.Query, warn: false
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Metadata.MediaMetadata

  alias Pinchflat.Lifecycle.UserScripts.CommandRunner, as: UserScriptRunner

  # Some fields should only be set on insert and not on update.
  @fields_to_drop_on_update [:playlist_index]

  @doc """
  Returns the list of media_items.

  Returns [%MediaItem{}, ...].
  """
  def list_media_items do
    Repo.all(MediaItem)
  end

  @doc """
  Returns a list of media_items that are upgradeable based on the redownload delay
  of the media_profile their source belongs to. In this context, upgradeable means
  that it's been long enough since upload that the video may be in a higher quality
  or have better sponsorblock segments (or similar).

  The logic is that a media_item is past_redownload_delay if the media_item's uploaded_at is
  at least redownload_delay_days ago AND `media_downloaded_at` - `redownload_delay_days`
  is before the media_item's `uploaded_at`.

  This logic grabs media that we've recently downloaded AND is recently uploaded, but
  doesn't grab media that we've recently downloaded and was uploaded a long time ago.
  This also makes things work as expected when downloading media from a source for the
  first time.

  Returns [%MediaItem{}, ...]
  """
  def list_upgradeable_media_items do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^MediaQuery.upgradeable())
    |> Repo.all()
  end

  @doc """
  Returns a list of pending media_items for a given source, where
  pending means the media_item satisfies `MediaQuery.pending`. You
  should really check out that function if you need to know more
  because it has a lot going on.

  Returns [%MediaItem{}, ...].
  """
  def list_pending_media_items_for(%Source{} = source) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.pending()))
    |> Repo.all()
  end

  @doc """
  For a given media_item, tells you if it is pending download. This is defined as
  the media_item satisfying `MediaQuery.pending` which you should really check out.

  Intentionally does not take the `download_media` setting of the source into account.

  Returns boolean()
  """
  @doc """
  Sets `prevent_download` for the given media item ids in one query.
  Optionally clears `last_error` when un-preventing.

  Returns {count, nil}
  """
  def set_prevent_download_for(media_item_ids, prevent?) when is_list(media_item_ids) do
    attrs = if prevent?, do: [prevent_download: true], else: [prevent_download: false, last_error: nil]

    from(m in MediaItem, where: m.id in ^media_item_ids)
    |> Repo.update_all(set: attrs)
  end

  @doc """
  Deletes all pending (not downloaded, not prevented) media items for a source
  without touching their (nonexistent) files. Useful for clearing out stuck or
  uninteresting entries (upstream #724).

  Returns {count, nil}
  """
  def delete_all_pending_for(%Source{} = source) do
    source
    |> list_pending_media_items_for()
    |> Enum.reduce(0, fn media_item, acc ->
      case delete_media_item(media_item, delete_files: false) do
        {:ok, _} -> acc + 1
        _ -> acc
      end
    end)
    |> then(&{&1, nil})
  end

  def pending_download?(%MediaItem{} = media_item) do
    media_item = Repo.preload(media_item, source: :media_profile)

    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic([m, s, mp], m.id == ^media_item.id and ^MediaQuery.pending()))
    |> Repo.exists?()
  end

  @doc """
  Returns a list of media_items that match the search term. Adds a `matching_search_term`
  virtual field to the result set.

  Has explit handling for blank search terms because SQLite doesn't like empty MATCH clauses.

  Returns [%MediaItem{}, ...].
  """
  def search(_search_term, _opts \\ [])
  def search("", _opts), do: []
  def search(nil, _opts), do: []

  def search(search_term, opts) do
    limit = Keyword.get(opts, :limit, 50)

    MediaQuery.new()
    |> MediaQuery.matching_search_term(search_term)
    |> Repo.maybe_limit(limit)
    |> Repo.all()
  end

  @doc """
  Lists media items that have a recorded error, most recently errored first.
  Optionally scoped to one source. Used by the errors console (upstream #870).

  Returns [%MediaItem{}, ...]
  """
  def list_errored_media_items(opts \\ []) do
    source_id = Keyword.get(opts, :source_id)
    limit = Keyword.get(opts, :limit, 100)

    MediaQuery.new()
    |> MediaQuery.require_assoc(:source)
    |> where(^MediaQuery.errored())
    |> apply_source_filter(source_id)
    |> order_by([mi], desc: mi.updated_at, desc: mi.id)
    |> limit(^limit)
    |> preload(:source)
    |> Repo.all()
  end

  defp apply_source_filter(query, nil), do: query
  defp apply_source_filter(query, source_id), do: where(query, [mi], mi.source_id == ^source_id)

  @doc """
  Gets a single media_item.

  Returns %MediaItem{}. Raises `Ecto.NoResultsError` if the Media item does not exist.
  """
  def get_media_item!(id), do: Repo.get!(MediaItem, id)

  @doc """
  Creates a media_item.

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def create_media_item(attrs) do
    %MediaItem{}
    |> MediaItem.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a media item from the attributes returned by the video backend
  (read: yt-dlp).

  Unlike `create_media_item`, this will attempt an update if the media_item
  already exists. This is so that future indexing can pick up attributes that
  we may not have asked for in the past (eg: uploaded_at)

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def create_media_item_from_backend_attrs(source, media_attrs_struct) do
    attrs = Map.merge(%{source_id: source.id}, Map.from_struct(media_attrs_struct))

    %MediaItem{}
    |> MediaItem.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set:
          attrs
          |> Map.drop(@fields_to_drop_on_update)
          |> Map.to_list()
      ],
      conflict_target: [:source_id, :media_id]
    )
  end

  @doc """
  Updates a media_item.

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def update_media_item(%MediaItem{} = media_item, attrs) do
    update_attrs = Map.drop(attrs, @fields_to_drop_on_update)

    media_item
    |> MediaItem.changeset(update_attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a media_item, its associated tasks, and our internal metadata files.
  Can optionally delete the media_item's media files (media, thumbnail, subtitles, etc).

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def delete_media_item(%MediaItem{} = media_item, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    Tasks.delete_tasks_for(media_item)

    if delete_files do
      {:ok, _} = do_delete_media_files(media_item)
      run_user_script(:media_deleted, media_item)
    end

    # Should delete these no matter what
    delete_internal_metadata_files(media_item)
    Repo.delete(media_item)
  end

  @doc """
  Deletes the tasks and media files associated with a media_item but leaves the
  media_item in the database. Does not delete anything to do with associated metadata.

  Optionally accepts a second argument `addl_attrs` which will be merged into the
  media_item before it is updated. Useful for setting things like `prevent_download`
  and `culled_at`, if wanted

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def delete_media_files(%MediaItem{} = media_item, addl_attrs \\ %{}) do
    filepath_attrs = MediaItem.filepath_attribute_defaults()

    Tasks.delete_tasks_for(media_item)
    {:ok, _} = do_delete_media_files(media_item)
    run_user_script(:media_deleted, media_item)

    update_media_item(media_item, Map.merge(filepath_attrs, addl_attrs))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking media_item changes.
  """
  def change_media_item(%MediaItem{} = media_item, attrs \\ %{}) do
    MediaItem.changeset(media_item, attrs)
  end

  defp do_delete_media_files(media_item) do
    mapped_struct = Map.from_struct(media_item)

    MediaItem.filepath_attributes()
    |> Enum.map(fn
      :subtitle_filepaths = field -> Enum.map(mapped_struct[field], fn [_, filepath] -> filepath end)
      field -> List.wrap(mapped_struct[field])
    end)
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)

    {:ok, media_item}
  end

  defp delete_internal_metadata_files(media_item) do
    metadata = Repo.preload(media_item, :metadata).metadata || %MediaMetadata{}
    mapped_struct = Map.from_struct(metadata)

    MediaMetadata.filepath_attributes()
    |> Enum.map(fn field -> mapped_struct[field] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)
  end

  defp run_user_script(event, media_item) do
    runner = Application.get_env(:pinchflat, :user_script_runner, UserScriptRunner)

    runner.run(event, media_item)
  end
end
