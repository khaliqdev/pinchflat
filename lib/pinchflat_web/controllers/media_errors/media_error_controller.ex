defmodule PinchflatWeb.MediaErrors.MediaErrorController do
  use PinchflatWeb, :controller

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Media
  alias Pinchflat.Media.ErrorSignature
  alias Pinchflat.Sources

  def retry(conn, params) do
    source_id = parse_source_id(params["source_id"])
    # Retry eligibility is applied BEFORE the 100-item cap: ignored and
    # already-downloaded items never clear on their own, so letting them into
    # the batch would wall off the oldest window and starve newer failures out
    # of every run. Re-running continues through the backlog. The scope
    # (all sources vs the currently-filtered source) matches the page state.
    retryable = Media.list_errored_media_items(source_id: source_id, limit: 100, retryable_only: true)

    # Errored items outside the retryable set (ignored, already-downloaded,
    # profile-excluded) are skipped rather than retried
    skipped =
      Media.count_errored_media_items(source_id: source_id) -
        Media.count_errored_media_items(source_id: source_id, retryable_only: true)

    Enum.each(retryable, fn item ->
      Media.update_media_item(item, %{last_error: nil})
      MediaDownloadWorker.kickoff_with_task(item)
    end)

    scope = if source_id, do: "in this source", else: "across all sources"

    cap_note =
      if length(retryable) == 100,
        do: " Batch covered the oldest 100 retryable failures - run it again for the next batch.",
        else: ""

    conn
    |> put_flash(
      :info,
      "Retried #{length(retryable)} item(s) #{scope} (skipped #{skipped} ignored or already downloaded).#{cap_note}"
    )
    |> redirect(to: ~p"/errors")
  end

  @doc """
  Retries only the checkbox-selected items from the errors console. Same gate
  as retry/2: the selection is narrowed to items on the retryable errored batch
  (the page only ever renders the first 100, and retry eligibility is applied
  before that cap); anything else selected is counted as skipped.
  """
  def retry_selected(conn, params) do
    selected_ids = parse_selected_ids(params["selected_ids"])

    if Enum.empty?(selected_ids) do
      redirect(conn, to: ~p"/errors")
    else
      source_id = parse_source_id(params["source_id"])
      retryable_batch = Media.list_errored_media_items(source_id: source_id, retryable_only: true)
      retryable = Enum.filter(retryable_batch, &(&1.id in selected_ids))
      skipped = length(selected_ids) - length(retryable)

      Enum.each(retryable, fn item ->
        Media.update_media_item(item, %{last_error: nil})
        MediaDownloadWorker.kickoff_with_task(item)
      end)

      conn
      |> put_flash(:info, "Retried #{length(retryable)} item(s) (skipped #{skipped} ignored or already downloaded)")
      |> redirect(to: ~p"/errors")
    end
  end

  def index(conn, params) do
    source_id = parse_source_id(params["source_id"])
    errors = Media.list_errored_media_items(source_id: source_id)

    render(conn, :index,
      errors: errors,
      error_groups: ErrorSignature.group(errors),
      total_errored: Media.count_errored_media_items(source_id: source_id),
      sources: Sources.list_sources(),
      source_id: source_id,
      page_title: "Errors"
    )
  end

  defp parse_source_id(nil), do: nil

  defp parse_source_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> int
      :error -> nil
    end
  end

  # Checkboxes post as selected_ids[]=1&selected_ids[]=2 (a bare value when
  # only one is checked); anything unparseable is dropped rather than raising
  defp parse_selected_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.map(&parse_selected_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp parse_selected_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_selected_id(_), do: nil
end
