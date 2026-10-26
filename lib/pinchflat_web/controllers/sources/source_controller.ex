defmodule PinchflatWeb.Sources.SourceController do
  use PinchflatWeb, :controller
  use Pinchflat.Sources.SourcesQuery

  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Media
  alias Pinchflat.Media.FileSyncingWorker
  alias Pinchflat.Sources.SourceDeletionWorker
  alias Pinchflat.Sources.SourceScanner
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  def index(conn, _params) do
    render(conn, :index)
  end

  def new(conn, params) do
    # This lets me preload the settings from another source for more efficient creation
    cs_struct =
      case to_string(params["template_id"]) do
        "" -> %Source{}
        template_id -> Repo.get(Source, template_id) || %Source{}
      end

    render(conn, :new,
      media_profiles: media_profiles(),
      layout: get_onboarding_layout(),
      # Most of these don't actually _need_ to be nullified at this point,
      # but if I don't do it now I know it'll bite me
      changeset:
        Sources.change_source(%Source{
          cs_struct
          | id: nil,
            uuid: nil,
            custom_name: nil,
            description: nil,
            collection_name: nil,
            collection_id: nil,
            collection_type: nil,
            original_url: nil,
            marked_for_deletion_at: nil
        })
    )
  end

  def create(conn, %{"source" => source_params}) do
    case Sources.create_source(source_params) do
      {:ok, source} ->
        redirect_location =
          if Settings.get!(:onboarding), do: ~p"/?onboarding=1", else: ~p"/sources/#{source}"

        conn
        |> put_flash(:info, "Source created successfully.")
        |> redirect(to: redirect_location)

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new,
          changeset: changeset,
          media_profiles: media_profiles(),
          layout: get_onboarding_layout()
        )
    end
  end

  def check_now(conn, %{"id" => id}) do
    source = Sources.get_source!(id)

    SlowIndexingHelpers.kickoff_indexing_task(source, %{force: true})

    conn
    |> put_flash(:info, "Indexing started - new videos will appear shortly")
    |> redirect(to: ~p"/sources/#{source}")
  end

  @doc """
  Runs a preview scan (ROADMAP 4.1) against the source-form values without
  saving anything and answers with JSON. The form's vanilla JS posts with the
  x-csrf-token header (read from the csrf-token meta tag), which the :browser
  pipeline's protect_from_forgery accepts.
  """
  def scan(conn, params) do
    case SourceScanner.scan_from_params(Map.get(params, "source", %{})) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, {:invalid, errors}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors})

      {:error, :timeout} ->
        conn
        |> put_status(:request_timeout)
        |> json(%{error: timeout_message()})

      {:error, {:scan_failed, message}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Scan failed: #{message}"})
    end
  end

  defp timeout_message do
    "Channel too large for preview (scan timed out after #{div(SourceScanner.timeout_ms(), 1000)}s). " <>
      "Saving the source and letting the first index run will still work."
  end

  def delete_pending(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    {count, _} = Media.delete_all_pending_for(source)

    conn
    |> put_flash(:info, "Deleted #{count} pending media item(s)")
    |> redirect(to: ~p"/sources/#{source}")
  end

  def show(conn, %{"id" => id}) do
    source = Repo.preload(Sources.get_source!(id), :media_profile)

    pending_tasks =
      source
      |> Tasks.list_tasks_for(nil, [:executing, :available, :scheduled, :retryable])
      |> Repo.preload(:job)

    cookie_behaviour_label =
      case {source.cookie_behaviour, source.cookies_required} do
        {:disabled, _} ->
          "Disabled"

        {:all_operations, _} ->
          "All operations"

        {:when_needed, true} ->
          "When needed — now using cookies for all operations"

        {:when_needed, false} ->
          "When needed — indexing and error recovery"
      end

    summary_assigns = %{
      source: source,
      pending_tasks: pending_tasks,
      last_indexed_at: source.last_indexed_at,
      next_index_at: next_index_at(source),
      output_directory: source.series_directory || Application.fetch_env!(:pinchflat, :media_directory),
      output_directory_label:
        if(source.series_directory,
          do: "Last resolved source directory",
          else: "Configured media root"
        ),
      output_directory_resolved: not is_nil(source.series_directory),
      effective_output_path_template: Sources.output_path_template(source),
      profile_name: source.media_profile.name,
      profile_href: ~p"/media_profiles/#{source.media_profile_id}",
      original_url: source.original_url,
      cookie_behaviour_label: cookie_behaviour_label,
      download_cutoff_date: source.download_cutoff_date
    }

    render(
      conn,
      :show,
      Map.merge(Media.source_summary_counts(source), summary_assigns)
    )
  end

  defp next_index_at(%Source{
         last_indexed_at: %DateTime{} = last_indexed_at,
         index_frequency_minutes: minutes
       })
       when is_integer(minutes) and minutes > 0 do
    DateTime.add(last_indexed_at, minutes * 60, :second)
  end

  defp next_index_at(%Source{}), do: nil

  def edit(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    changeset = Sources.change_source(source)

    render(conn, :edit, source: source, changeset: changeset, media_profiles: media_profiles())
  end

  def update(conn, %{"id" => id, "source" => source_params}) do
    source = Sources.get_source!(id)

    case Sources.update_source(source, source_params) do
      {:ok, source} ->
        conn
        |> put_flash(:info, "Source updated successfully.")
        |> redirect(to: ~p"/sources/#{source}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit,
          source: source,
          changeset: changeset,
          media_profiles: media_profiles()
        )
    end
  end

  def delete(conn, %{"id" => id} = params) do
    # This awkward comparison converts the string to a boolean
    delete_files = Map.get(params, "delete_files", "") == "true"
    source = Sources.get_source!(id)

    {:ok, _} = Sources.update_source(source, %{marked_for_deletion_at: DateTime.utc_now()})
    SourceDeletionWorker.kickoff(source, %{delete_files: delete_files})

    conn
    |> put_flash(:info, "Source deletion started. This may take a while to complete.")
    |> redirect(to: ~p"/sources")
  end

  def force_download_pending(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Forcing download of pending media items.",
      &DownloadingHelpers.enqueue_pending_download_tasks/1
    )
  end

  def force_redownload(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Forcing re-download of downloaded media items.",
      &DownloadingHelpers.kickoff_redownload_for_existing_media/1
    )
  end

  def force_index(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Index enqueued.",
      &SlowIndexingHelpers.kickoff_indexing_task(&1, %{force: true})
    )
  end

  def force_metadata_refresh(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Metadata refresh enqueued.",
      &SourceMetadataStorageWorker.kickoff_with_task/1
    )
  end

  def sync_files_on_disk(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "File sync enqueued.",
      &FileSyncingWorker.kickoff_with_task/1
    )
  end

  defp wrap_forced_action(conn, source_id, message, fun) do
    source = Sources.get_source!(source_id)
    fun.(source)

    conn
    |> put_flash(:info, message)
    |> redirect(to: ~p"/sources/#{source}")
  end

  defp media_profiles do
    MediaProfile
    |> order_by(asc: :name)
    |> Repo.all()
  end

  defp get_onboarding_layout do
    if Settings.get!(:onboarding) do
      {Layouts, :onboarding}
    else
      {Layouts, :app}
    end
  end
end
