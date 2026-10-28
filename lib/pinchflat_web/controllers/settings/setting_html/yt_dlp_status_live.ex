defmodule Pinchflat.Settings.YtDlpStatusLive do
  @moduledoc """
  App Info card showing the installed yt-dlp version against the latest
  stable release, with on-demand Check and Update-now actions.

  Check hits GitHub synchronously (VersionCheck - one request, bounded by
  the HTTP client's 30s timeout) and assigns the result inline. Update-now
  enqueues the existing UpdateWorker (Oban, so the request never blocks)
  and polls the job until it completes - the worker records the resulting
  version in Settings, which is what the poll compares. The "Update now"
  button enqueues the job as manual, which bypasses the auto-update mode
  gate, and a failed update is reported as a failure rather than success.

  The auto-update mode (nightly / boot / off) is read-only here: it comes
  from the container's YT_DLP_AUTO_UPDATE env var, which a web UI cannot
  rewrite.
  """

  use PinchflatWeb, :live_view

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.YtDlp.UpdateWorker
  alias Pinchflat.YtDlp.VersionCheck

  @poll_ms 3_000
  @max_polls 40

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_version: Settings.get!(:yt_dlp_version),
       latest_version: nil,
       auto_update_mode: Application.get_env(:pinchflat, :yt_dlp_auto_update, "nightly"),
       checking: false,
       updating: false,
       status: nil,
       status_kind: :info
     )}
  end

  def render(assigns) do
    ~H"""
    <div class="rounded-sm border border-stroke bg-white px-5 py-5 shadow-default dark:border-strokedark dark:bg-boxdark sm:px-7.5 mt-4">
      <div class="mb-4 flex flex-wrap items-center justify-between gap-2">
        <h3 class="text-title-md2 font-bold text-black dark:text-white">yt-dlp</h3>
        <%= case VersionCheck.version_state(@current_version, @latest_version) do %>
          <% :update_available -> %>
            <span class={badge_classes(:update)}>update available</span>
          <% :newer_installed -> %>
            <span class={badge_classes(:update)}>newer than stable</span>
          <% :up_to_date -> %>
            <span class={badge_classes(:up_to_date)}>up to date</span>
          <% _ -> %>
        <% end %>
      </div>

      <dl class="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <div>
          <dt class="text-sm text-zinc-600 dark:text-bodydark">Installed</dt>
          <dd class="mt-1 font-mono text-sm font-medium text-black dark:text-white">{@current_version || "unknown"}</dd>
        </div>
        <div>
          <dt class="text-sm text-zinc-600 dark:text-bodydark">Latest stable</dt>
          <dd class="mt-1 font-mono text-sm font-medium text-black dark:text-white">
            <%= if @checking do %>
              <span class="inline-block h-3 w-3 animate-pulse rounded-full bg-primary"></span>
            <% else %>
              {@latest_version || "not checked"}
            <% end %>
          </dd>
        </div>
        <div>
          <dt class="text-sm text-zinc-600 dark:text-bodydark">Auto-update</dt>
          <dd class="mt-1 text-sm font-medium text-black dark:text-white">
            {@auto_update_mode}
            <span class="block text-xs font-normal text-bodydark2">set via YT_DLP_AUTO_UPDATE in the container</span>
          </dd>
        </div>
      </dl>

      <div class="mt-5 flex flex-wrap gap-3">
        <button
          type="button"
          phx-click="check"
          disabled={@checking || @updating}
          class="inline-flex h-10 items-center rounded-md border border-primary px-4 text-sm font-medium text-primary hover:bg-primary hover:text-white disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 dark:focus-visible:ring-offset-boxdark"
        >
          <%= if @checking do %>
            Checking…
          <% else %>
            Check for updates
          <% end %>
        </button>

        <button
          type="button"
          phx-click="update"
          disabled={@updating || @checking}
          class="inline-flex h-10 items-center rounded-md bg-primary px-4 text-sm font-medium text-white hover:bg-opacity-90 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 dark:focus-visible:ring-offset-boxdark"
        >
          <%= if @updating do %>
            Updating… <span class="ml-2 inline-block h-3 w-3 animate-pulse rounded-full bg-white/70"></span>
          <% else %>
            Update now
          <% end %>
        </button>
      </div>

      <p
        :if={@status}
        class={[
          "mt-4 rounded-md border px-3 py-2 text-sm",
          @status_kind == :ok &&
            "border-green-200 bg-green-50 text-green-700 dark:border-green-500/20 dark:bg-green-500/10 dark:text-green-400",
          @status_kind == :error &&
            "border-red-200 bg-red-50 text-red-700 dark:border-red-500/20 dark:bg-red-500/10 dark:text-red-400",
          @status_kind == :info && "border-stroke bg-gray-2 text-body dark:border-strokedark dark:bg-meta-4"
        ]}
      >
        {@status}
      </p>
    </div>
    """
  end

  def handle_event("check", _params, socket) do
    {:noreply, assign(socket, checking: true) |> run_check()}
  end

  def handle_event("update", _params, socket) do
    case UpdateWorker.kickoff(manual: true) do
      {:ok, %Oban.Job{id: job_id}} ->
        {:noreply,
         socket
         |> assign(
           updating: true,
           job_id: job_id,
           before_version: socket.assigns.current_version,
           poll_count: 0,
           latest_version: nil,
           status: "Update queued - running now…",
           status_kind: :info
         )
         |> schedule_poll()}

      _error ->
        {:noreply, assign(socket, status: "Could not queue the update worker - check the logs.", status_kind: :error)}
    end
  end

  def handle_info(:poll, %{assigns: %{job_id: job_id}} = socket) do
    case Repo.get(Oban.Job, job_id) do
      %{state: "completed"} ->
        after_version = Settings.get!(:yt_dlp_version)
        before = socket.assigns.before_version

        message =
          if before && after_version && before != after_version do
            "Updated yt-dlp #{before} → #{after_version}."
          else
            "Updater finished - yt-dlp is on #{after_version || "an unknown version"}."
          end

        {:noreply,
         assign(socket,
           updating: false,
           current_version: after_version,
           status: message,
           status_kind: :ok
         )}

      %{state: state} when state in ["discarded", "cancelled", "retryable"] ->
        {:noreply,
         assign(socket,
           updating: false,
           status: "Update failed (job #{state}) - see the logs for why.",
           status_kind: :error
         )}

      _still_running ->
        count = Map.get(socket.assigns, :poll_count, 0) + 1

        if count >= @max_polls do
          {:noreply,
           assign(socket,
             updating: false,
             status:
               "Update is still running after #{div(@max_polls * @poll_ms, 1000)}s - refresh this page in a minute.",
             status_kind: :info
           )}
        else
          {:noreply, assign(socket, poll_count: count) |> schedule_poll()}
        end
    end
  end

  # The synchronous GitHub fetch happens in the event process - bounded by
  # the HTTP client's 30s timeout, and the button shows "Checking…" meanwhile
  defp run_check(socket) do
    case version_check().latest_stable_version() do
      {:ok, latest} ->
        assign(socket,
          checking: false,
          latest_version: latest,
          status: nil
        )

      {:error, reason} ->
        assign(socket,
          checking: false,
          status: "Check failed - #{reason}",
          status_kind: :error
        )
    end
  end

  defp schedule_poll(socket) do
    Process.send_after(self(), :poll, @poll_ms)

    socket
  end

  defp version_check do
    Application.get_env(:pinchflat, :yt_dlp_version_check, VersionCheck)
  end

  # Badge classes live in a function, not module attributes: inside ~H,
  # @-references resolve to socket assigns and would raise at render time
  defp badge_classes(:update) do
    "rounded-md border border-amber-200 bg-amber-50 px-2 py-0.5 text-xs font-semibold text-amber-800 dark:border-amber-500/20 dark:bg-amber-500/10 dark:text-amber-400"
  end

  defp badge_classes(:up_to_date) do
    "rounded-md border border-green-200 bg-green-50 px-2 py-0.5 text-xs font-semibold text-green-700 dark:border-green-500/20 dark:bg-green-500/10 dark:text-green-400"
  end
end
