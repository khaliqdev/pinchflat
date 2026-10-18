defmodule Pinchflat.Pages.StatusChipsLive do
  @moduledoc """
  Compact live status chips for the top nav: errored media count and
  actively-downloading count. Updates via the "job:state" PubSub topic and a
  periodic refresh (errors can appear outside job events, eg. via retention).

  Renders nothing when there's nothing to show.
  """

  use PinchflatWeb, :live_view

  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo

  @refresh_ms 30_000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      PinchflatWeb.Endpoint.subscribe("job:state")
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok, assign(socket, counts: compute_counts())}
  end

  def render(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <.link
        :if={@counts.errored > 0}
        href={~p"/errors"}
        class="flex items-center gap-1.5 rounded-md border border-red-500/20 bg-red-500/10 px-2.5 py-1.5 text-xs font-medium text-red-400 hover:bg-red-500/20"
      >
        <.icon name="hero-exclamation-triangle" class="h-4 w-4" />
        <.localized_number number={@counts.errored} />
      </.link>
      <span
        :if={@counts.downloading > 0}
        class="flex animate-pulse items-center gap-1.5 rounded-md border border-sky-500/20 bg-sky-500/10 px-2.5 py-1.5 text-xs font-medium text-sky-400"
      >
        <.icon name="hero-arrow-down-tray" class="h-4 w-4" />
        <.localized_number number={@counts.downloading} />
      </span>
    </div>
    """
  end

  def handle_info(%{topic: "job:state"}, socket) do
    {:noreply, assign(socket, counts: compute_counts())}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    {:noreply, assign(socket, counts: compute_counts())}
  end

  defp compute_counts do
    errored =
      MediaQuery.new()
      |> where(^MediaQuery.errored())
      |> Repo.aggregate(:count, :id)

    downloading =
      from(t in Pinchflat.Tasks.Task,
        join: j in Oban.Job,
        on: j.id == t.job_id,
        where: j.state == "executing" and "media_item" in j.tags and like(j.worker, "%MediaDownloadWorker"),
        select: t.media_item_id
      )
      |> Repo.all()
      |> Enum.uniq()
      |> length()

    %{errored: errored, downloading: downloading}
  end
end
