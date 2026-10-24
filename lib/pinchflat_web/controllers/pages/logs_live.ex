defmodule Pinchflat.Pages.LogsLive do
  @moduledoc """
  Config → Logs viewer (ROADMAP Phase 5.2): streams the in-app log buffer
  (`Pinchflat.Logs.LogBuffer`) into a monospace console styled like the
  /errors page, theme-aware in both light and dark mode.

  Live-follow rides the throttled `log_buffer` topic: each "append" tick is
  seq-guarded so no-op ticks are skipped, and a tick recomputes the snapshot
  from the bounded buffer - a chatty debug firehose costs one ~500ms
  re-render, never one per line, and counts stay true as lines roll off the
  ring. Pausing freezes the view; resuming does a full catch-up re-read.

  Rendering stays chunked: at most `@max_rendered` lines are ever in the
  DOM (the newest ones), and older chunks load on demand via "Show older".
  Search, level chips (with whole-buffer counts) and source chips
  (worker/module labels derived by the buffer) all filter client-side from
  the same snapshot.

  The default level filter excludes :debug. Production still defaults
  LOG_LEVEL to debug (runtime.exs), and this default is the resolution of
  the spec's open decision - everything stays captured in the buffer, one
  chip click reveals it.
  """

  use PinchflatWeb, :live_view

  alias Pinchflat.Logs.LogBuffer

  @initial_lines 200
  @chunk_lines 250
  @max_rendered 1_000
  @default_levels [:info, :warning, :error]
  @levels [:debug, :info, :warning, :error]

  def mount(_params, _session, socket) do
    if connected?(socket) do
      PinchflatWeb.Endpoint.subscribe("log_buffer")
    end

    socket =
      socket
      |> assign(
        following: true,
        selected_levels: MapSet.new(@default_levels),
        selected_source: nil,
        search: "",
        visible_lines: @initial_lines,
        # The render reads the DOM cap as an assign (reload/1 uses the module
        # attribute for the same bound)
        max_rendered: @max_rendered,
        last_seq: 0,
        levels: @levels
      )
      |> reload()

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <div class="rounded-sm border border-stroke bg-white px-5 py-4 shadow-default dark:border-strokedark dark:bg-boxdark">
        <div class="flex flex-wrap items-center gap-2">
          <nav class="flex flex-wrap items-center gap-2">
            <button
              :for={level <- @levels}
              type="button"
              phx-click="toggle-level"
              phx-value-level={level}
              class={["rounded-md border px-3 py-1.5 text-sm font-medium capitalize", chip_state(level, level in @selected_levels)]}
            >
              {level} <span class="ml-1 font-normal opacity-75 tabular-nums">{@level_counts[level]}</span>
            </button>
          </nav>

          <span class="hidden h-5 w-px bg-stroke dark:bg-strokedark sm:block"></span>

          <nav class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              phx-click="select-source"
              phx-value-source=""
              class={["rounded-md border px-3 py-1.5 text-sm font-medium", chip_state(is_nil(@selected_source))]}
            >
              All modules
            </button>
            <button
              :for={source <- @sources}
              type="button"
              phx-click="select-source"
              phx-value-source={source}
              class={["rounded-md border px-3 py-1.5 text-sm font-medium", chip_state(@selected_source == source)]}
            >
              {source}
            </button>
          </nav>
        </div>

        <div class="mt-3 flex flex-wrap items-center gap-3">
          <.form for={%{}} phx-change="search" class="contents">
            <input
              type="text"
              name="search"
              value={@search}
              placeholder="Search log lines..."
              phx-debounce="200"
              aria-label="Search log lines"
              class="w-64 rounded-md border border-stroke bg-transparent px-3 py-1.5 text-sm text-body dark:text-bodydark1 outline-none focus:border-primary dark:border-strokedark"
            />
          </.form>

          <button
            type="button"
            phx-click="toggle-follow"
            class={[
              "rounded-md border px-3 py-1.5 text-sm font-medium",
              @following && "border-primary text-primary hover:bg-primary hover:text-white",
              !@following && "border-stroke text-bodydark2 hover:text-bodydark1 dark:border-strokedark"
            ]}
          >
            {if @following, do: "Pause follow", else: "Resume follow"}
          </button>

          <.link
            href={~p"/logs/download?lines=#{@total}"}
            class="rounded-md border border-stroke px-3 py-1.5 text-sm font-medium text-bodydark2 hover:text-bodydark1 dark:border-strokedark"
          >
            Download buffer ({@total} lines)
          </.link>

          <span class="ml-auto text-xs text-bodydark2 tabular-nums">
            showing {length(@lines)} of {@matched_count} matching ({@total} buffered since boot)
          </span>
        </div>
      </div>

      <div class="rounded-sm border border-stroke bg-white px-5 py-4 shadow-default dark:border-strokedark dark:bg-boxdark">
        <div
          id="logs-scroll"
          phx-hook="LogsAutoScroll"
          class="flex flex-col gap-0 overflow-y-auto rounded-md border border-stroke bg-gray-2 p-3 font-mono text-[13px] leading-5 dark:border-strokedark dark:bg-meta-4"
          style="max-height: 70vh"
        >
          <div :if={@lines == []} class="text-bodydark2">
            No matching log lines.
          </div>

          <div :for={entry <- @lines} id={"log-entry-#{entry.seq}"} class={["m-0 shrink-0 whitespace-pre-wrap break-words p-0 text-[13px] leading-5", line_class(entry.level)]}><%= entry.line %></div>
        </div>

        <div class="mt-3 flex flex-wrap items-center justify-center gap-3">
          <button
            :if={@matched_count > length(@lines)}
            type="button"
            phx-click="show-older"
            class="rounded-md border border-stroke px-3 py-1.5 text-sm font-medium text-bodydark2 hover:text-bodydark1 dark:border-strokedark"
          >
            Show older
          </button>
          <span :if={@matched_count > @max_rendered} class="text-xs text-bodydark2">
            Showing the newest {@max_rendered} matching lines - narrow the filters to see more.
          </span>
        </div>
      </div>
    </div>
    """
  end

  # Filtering events all re-read the buffer: it's bounded (5k lines) and the
  # snapshot must stay consistent with the new filter set

  def handle_event("toggle-level", %{"level" => level}, socket) when level in ~w(debug info warning error) do
    level = String.to_existing_atom(level)

    selected =
      if MapSet.member?(socket.assigns.selected_levels, level) do
        MapSet.delete(socket.assigns.selected_levels, level)
      else
        MapSet.put(socket.assigns.selected_levels, level)
      end

    {:noreply, socket |> assign(selected_levels: selected) |> reload()}
  end

  # Unknown level strings are dropped instead of crashing the session
  def handle_event("toggle-level", _params, socket), do: {:noreply, socket}

  def handle_event("select-source", %{"source" => source}, socket) do
    source = if source == "", do: nil, else: source

    {:noreply, socket |> assign(selected_source: source) |> reload()}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(search: search || "") |> reload()}
  end

  # Pausing freezes assigns; resuming re-reads and catches up
  def handle_event("toggle-follow", _params, %{assigns: %{following: true}} = socket) do
    {:noreply, assign(socket, following: false)}
  end

  def handle_event("toggle-follow", _params, socket) do
    {:noreply, socket |> assign(following: true) |> reload()}
  end

  def handle_event("show-older", _params, socket) do
    {:noreply, socket |> update(:visible_lines, &(&1 + @chunk_lines)) |> reload()}
  end

  # Paused viewers ignore ticks entirely; resuming reloads and catches up.
  # Every live tick recomputes the snapshot, so counts stay true even as
  # lines roll off the ring's cap
  def handle_info(%{topic: "log_buffer", event: "append"}, %{assigns: %{following: false}} = socket) do
    {:noreply, socket}
  end

  def handle_info(%{topic: "log_buffer", event: "append", payload: _payload}, socket) do
    case LogBuffer.since(socket.assigns.last_seq) do
      [] ->
        {:noreply, socket}

      _fresh ->
        {:noreply, socket |> reload() |> push_event("logs:autoscroll", %{})}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # Re-reads the whole bounded buffer and recomputes every derived assign -
  # the single source of truth for filter/search/chunk state
  defp reload(socket) do
    entries = LogBuffer.all()
    matched = Enum.filter(entries, &matches_filters?(&1, socket.assigns))

    assign(socket,
      lines:
        matched
        |> Enum.take(-min(socket.assigns.visible_lines, @max_rendered))
        |> Enum.map(fn entry ->
          # Viewer-only compact formatting: the stored line (searched here and
          # exported verbatim) keeps the full docker-logs metadata
          %{entry | line: LogBuffer.format_line(entry, :compact)}
        end),
      last_seq: current_seq(entries, socket.assigns.last_seq),
      matched_count: length(matched),
      total: length(entries),
      level_counts: LogBuffer.counts(),
      sources: LogBuffer.sources()
    )
  end

  defp current_seq([], fallback), do: fallback
  defp current_seq(entries, _fallback), do: entries |> List.last() |> Map.get(:seq)

  defp matches_filters?(entry, assigns) do
    level_ok = MapSet.member?(assigns.selected_levels, entry.level)
    source_ok = is_nil(assigns.selected_source) or assigns.selected_source == entry.source

    search_ok =
      assigns.search == "" or
        String.contains?(String.downcase(entry.line), String.downcase(assigns.search))

    level_ok and source_ok and search_ok
  end

  # Mirrors the /errors filter chips: active is primary, inactive is muted
  defp chip_state(true) do
    "border-blue-200 bg-blue-50 text-blue-700 dark:border-primary dark:bg-transparent dark:text-primary"
  end

  defp chip_state(false) do
    "border-stroke bg-transparent text-zinc-600 hover:text-zinc-900 dark:border-strokedark dark:text-bodydark2 dark:hover:text-bodydark1"
  end

  defp chip_state(_level, false) do
    "border-stroke text-zinc-600 hover:text-zinc-900 dark:border-strokedark dark:text-bodydark2 dark:hover:text-bodydark1"
  end

  defp chip_state(:error, true) do
    "border-red-200 bg-red-50 text-red-700 dark:border-primary dark:bg-transparent dark:text-primary"
  end

  defp chip_state(:warning, true) do
    "border-amber-200 bg-amber-50 text-amber-800 dark:border-primary dark:bg-transparent dark:text-primary"
  end

  defp chip_state(:info, true) do
    "border-blue-200 bg-blue-50 text-blue-700 dark:border-primary dark:bg-transparent dark:text-primary"
  end

  defp chip_state(:debug, true) do
    "border-stroke bg-gray text-zinc-700 dark:border-primary dark:bg-transparent dark:text-primary"
  end

  defp line_class(:error), do: "text-red-700 dark:text-red-400"
  defp line_class(:warning), do: "text-amber-800 dark:text-amber-400"
  defp line_class(:debug), do: "text-zinc-600 dark:text-bodydark2"
  defp line_class(_level), do: "text-zinc-800 dark:text-bodydark1"
end
