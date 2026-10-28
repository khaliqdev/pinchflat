defmodule PinchflatWeb.Pages.PageHTML do
  use PinchflatWeb, :html

  alias Pinchflat.Utils.DisplayTime
  alias Pinchflat.Utils.NumberUtils

  embed_templates "page_html/*"

  @doc """
  Relative age for dashboard tiles: today, Nd ago, or the ISO date past a
  week. Nil-safe for legacy items without a timestamp. Both sides go through
  DisplayTime so the comparison is local-date vs local-date, not local vs UTC.
  """
  def days_ago(datetime, now \\ DateTime.utc_now())

  def days_ago(nil, _now), do: "unknown"

  def days_ago(datetime, now) do
    date = DisplayTime.date_to_local(datetime)
    today = DisplayTime.date_to_local(now)
    days = Date.diff(today, date)

    cond do
      days <= 0 -> "today"
      days == 1 -> "yesterday"
      days < 7 -> "#{days}d ago"
      true -> Date.to_iso8601(date)
    end
  end

  @doc """
  Seconds -> "H:MM:SS" (or "M:SS") for the poster duration badge. Nil-safe.
  """
  def format_duration(nil), do: ""

  def format_duration(seconds) when is_integer(seconds) and seconds > 0 do
    h = div(seconds, 3600)
    m = rem(seconds, 3600) |> div(60)
    s = rem(seconds, 60)

    if h > 0 do
      :io_lib.format("~B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
    else
      :io_lib.format("~B:~2..0B", [m, s]) |> IO.iodata_to_binary()
    end
  end

  def format_duration(_), do: ""

  @doc """
  Card for the home-page shelves: cover art, duration badge, title, source.
  Scales up with a focus ring on hover/keyboard focus - the YouTube-on-TV
  look. `class` lands on the link (snap points, widths).
  """
  attr :item, :map, required: true
  attr :class, :string, default: ""

  def tv_media_card(assigns) do
    ~H"""
    <.link
      href={~p"/sources/#{@item.source_id}/media/#{@item}"}
      data-shelf-card
      class={[
        "group block w-52 shrink-0 snap-start outline-none transition-transform duration-200 ease-out",
        "hover:scale-[1.05] focus-visible:scale-[1.05] sm:w-60",
        @class
      ]}
    >
      <div class="relative aspect-video overflow-hidden rounded-xl bg-zinc-300 ring-1 ring-black/10 transition duration-200 group-hover:shadow-2xl group-hover:shadow-black/30 group-hover:ring-2 group-hover:ring-primary/60 group-focus-visible:ring-2 group-focus-visible:ring-primary dark:bg-meta-4 dark:ring-white/10 dark:group-hover:ring-white/70 dark:group-focus-visible:ring-white">
        <img
          :if={media_thumbnail_src(@item)}
          src={media_thumbnail_src(@item)}
          alt=""
          loading="lazy"
          class="h-full w-full object-cover"
          onerror="this.classList.add('hidden')"
        />
        <span
          :if={@item.duration_seconds}
          class="absolute bottom-1.5 right-1.5 rounded bg-black/75 px-1.5 py-0.5 text-[11px] font-medium text-white"
        >
          {format_duration(@item.duration_seconds)}
        </span>
      </div>
      <div class="mt-2 px-0.5">
        <div class="line-clamp-2 text-[13px] font-medium leading-snug text-black dark:text-white">
          {@item.title}
        </div>
        <div class="mt-0.5 truncate text-xs text-bodydark2">
          {@item.source.custom_name} · {days_ago(@item.media_downloaded_at)}
        </div>
      </div>
    </.link>
    """
  end

  @doc """
  Best-available thumbnail URL for a media item: the locally-stored file when
  present, otherwise YouTube's CDN fetched by the browser. Nil when neither
  is possible.
  """
  def media_thumbnail_src(item) do
    cond do
      item.thumbnail_filepath && item.uuid -> ~p"/media/#{item.uuid}/episode_image"
      item.media_id -> "https://i.ytimg.com/vi/#{item.media_id}/mqdefault.jpg"
      true -> nil
    end
  end

  @doc """
  Hero backdrop source - prefers the local thumbnail, otherwise YouTube's
  highest-resolution still.
  """
  def hero_image_src(item) do
    cond do
      is_nil(item) -> nil
      item.thumbnail_filepath && item.uuid -> ~p"/media/#{item.uuid}/episode_image"
      item.media_id -> "https://i.ytimg.com/vi/#{item.media_id}/maxresdefault.jpg"
      true -> nil
    end
  end

  @doc """
  Plain-string byte size for title tooltips where a component can't be used.
  """
  def filesize_string(bytes) do
    {num, suffix} = NumberUtils.human_byte_size(bytes, precision: 2)
    "#{num} #{suffix}"
  end

  @doc """
  onerror chain for the hero backdrop: fall back to YouTube's small still
  (maxresdefault often doesn't exist), or hide when there's no fallback.
  """
  def hero_image_onerror(item) do
    if item && item.media_id do
      "this.onerror=null;this.src='https://i.ytimg.com/vi/#{item.media_id}/hqdefault.jpg'"
    else
      "this.classList.add('hidden')"
    end
  end
end
