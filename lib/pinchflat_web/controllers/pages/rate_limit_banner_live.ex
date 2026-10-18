defmodule Pinchflat.Pages.RateLimitBannerLive do
  @moduledoc """
  Renders a banner across the top of every page while a YouTube rate-limit
  cooldown is active, so stalled downloads are never indistinguishable from
  hung ones. Updates live via the "rate_limit" PubSub topic.
  """

  use PinchflatWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket), do: PinchflatWeb.Endpoint.subscribe("rate_limit")

    {:ok, assign(socket, until: current_until())}
  end

  def render(assigns) do
    ~H"""
    <div
      :if={@until}
      class="mb-4 flex items-center gap-2 rounded-md border border-amber-500/20 bg-amber-500/10 px-4 py-3 text-amber-400"
    >
      <.icon name="hero-clock" class="h-5 w-5" />
      <span>
        YouTube rate limit active - yt-dlp work is paused until {format_time(@until)} to
        avoid deepening the block.
      </span>
    </div>
    """
  end

  def handle_info(%{topic: "rate_limit"}, socket) do
    {:noreply, assign(socket, until: current_until())}
  end

  defp current_until do
    if Pinchflat.RateLimit.tripped?() do
      DateTime.add(DateTime.utc_now(), Pinchflat.RateLimit.seconds_remaining(), :second)
    end
  end

  defp format_time(datetime) do
    datetime
    |> DateTime.to_time()
    |> Calendar.strftime("%H:%M")
  end
end
