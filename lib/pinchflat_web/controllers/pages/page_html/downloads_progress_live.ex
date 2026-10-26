defmodule Pinchflat.Pages.DownloadsProgressLive do
  @moduledoc """
  Home-page card listing actively-downloading media with live percent/speed/
  ETA. The row set is DB-driven (`Media.downloading_media_items/0` - jobs in
  the executing state), decorated with progress from the DownloadProgress ETS
  snapshot plus "download_progress" topic ticks. A download without progress
  data renders an indeterminate pulse bar.

  Renders nothing at all when no downloads are running, so the home page
  doesn't grow an empty card box.
  """

  use PinchflatWeb, :live_view

  alias Pinchflat.Media
  alias Pinchflat.Utils.NumberUtils
  alias Pinchflat.Downloading.DownloadProgress

  @refresh_ms 30_000
  # Job events arrive in bursts; coalesce like the status chips do instead
  # of requerying per event
  @job_state_debounce_ms 400

  def mount(_params, _session, socket) do
    if connected?(socket) do
      PinchflatWeb.Endpoint.subscribe("download_progress")
      PinchflatWeb.Endpoint.subscribe("job:state")
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    items = Media.downloading_media_items()

    {:ok,
     assign(socket,
       items: items,
       progress: progress_for_items(items),
       debounce_timer: nil
     )}
  end

  # The card shell lives here, not in home.html.heex, so an idle server
  # renders no empty box at all
  def render(%{items: []} = assigns) do
    ~H""
  end

  def render(assigns) do
    ~H"""
    <div class="rounded-sm border shadow-default border-stroke dark:border-strokedark bg-white dark:bg-boxdark mt-4 p-5">
      <span class="text-2xl font-medium mb-4 text-black dark:text-white">Downloading</span>

      <div class="mt-2 divide-y divide-stroke dark:divide-strokedark">
        <div :for={item <- @items} class="flex items-center gap-3 py-2.5">
          <% progress = Map.get(@progress, item.id) %>
          <% percent = progress && progress[:percent] %>
          <img
            :if={thumbnail_src(item)}
            src={thumbnail_src(item)}
            alt=""
            loading="lazy"
            class="h-9 w-16 shrink-0 rounded-md border border-stroke dark:border-strokedark object-cover"
            onerror="this.classList.add('hidden')"
          />

          <div class="min-w-0 flex-1">
            <div class="flex items-center justify-between gap-2">
              <.link
                href={~p"/sources/#{item.source_id}/media/#{item}"}
                class="truncate text-sm font-medium text-black dark:text-white hover:underline"
              >
                {item.title}
              </.link>

              <span :if={is_number(percent)} class="shrink-0 text-xs font-medium tabular-nums text-sky-400">
                {percent}%
              </span>
            </div>

            <div class="mt-1.5 h-1.5 w-full overflow-hidden rounded-full border border-sky-500/20 bg-sky-500/10">
              <div
                :if={is_number(percent)}
                class="h-full rounded-full bg-sky-500 transition-width duration-300 ease-out"
                style={"width: #{bar_width(percent)}%"}
              >
              </div>

              <div :if={not is_number(percent)} class="h-full w-full animate-pulse rounded-full bg-sky-500/40"></div>
            </div>

            <div
              :if={progress && (progress[:speed] || progress[:eta])}
              class="mt-1 flex items-center gap-3 text-xs text-bodydark2"
            >
              <span :if={progress && progress[:speed]}>{progress[:speed]}</span>
              <span :if={progress && progress[:eta]}>ETA {progress[:eta]}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Progress ticks only update assigns - never requery the DB per tick. Rows
  # come and go via job:state events (and the periodic refresh). The payload
  # is broadcast data (external input); tolerate missing keys instead of
  # crashing the LiveView on a malformed event.
  def handle_info(
        %{topic: "download_progress", event: "progress", payload: %{media_item_id: media_item_id} = payload},
        socket
      ) do
    progress = %{percent: payload[:percent], speed: payload[:speed], eta: payload[:eta]}

    if Enum.any?(socket.assigns.items, &(&1.id == media_item_id)) do
      {:noreply, update(socket, :progress, &Map.put(&1, media_item_id, progress))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{topic: "job:state", event: "change"}, %{assigns: %{debounce_timer: timer}} = socket)
      when is_reference(timer) do
    {:noreply, socket}
  end

  def handle_info(%{topic: "job:state", event: "change"}, socket) do
    timer = Process.send_after(self(), :job_state_settled, @job_state_debounce_ms)

    {:noreply, assign(socket, debounce_timer: timer)}
  end

  def handle_info(:job_state_settled, socket) do
    {:noreply, socket |> assign(debounce_timer: nil) |> recompute_items()}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    {:noreply, recompute_items(socket)}
  end

  defp recompute_items(socket) do
    items = Media.downloading_media_items()

    assign(socket, items: items, progress: progress_for_items(items))
  end

  # Keeps progress pruned to the current row set so stale entries can't
  # accumulate on long-lived connections
  defp progress_for_items(items) do
    current_ids = MapSet.new(items, & &1.id)

    DownloadProgress.snapshot()
    |> Map.filter(fn {id, _row} -> MapSet.member?(current_ids, id) end)
  end

  # Percent is clamped at record time, but the broadcast payload is external
  # input - format defensively for the style attribute
  defp bar_width(percent) when is_number(percent), do: NumberUtils.clamp(percent, 0, 100)

  # Downloaded items use the locally-stored thumbnail (served by UUID);
  # pending items fall back to YouTube's own CDN thumbnail, fetched by the
  # BROWSER so the server never contacts YouTube for these. Broken thumbs
  # hide themselves.
  defp thumbnail_src(item) do
    cond do
      item.thumbnail_filepath && item.uuid -> ~p"/media/#{item.uuid}/episode_image"
      item.media_id -> "https://i.ytimg.com/vi/#{item.media_id}/mqdefault.jpg"
      true -> nil
    end
  end
end
