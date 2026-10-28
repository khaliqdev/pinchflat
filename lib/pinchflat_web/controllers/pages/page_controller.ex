defmodule PinchflatWeb.Pages.PageController do
  use PinchflatWeb, :controller
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Utils.DiskUtils
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile

  def home(conn, params) do
    done_onboarding = params["onboarding"] == "0"
    force_onboarding = params["onboarding"] == "1"

    if done_onboarding, do: Settings.set(onboarding: false)

    if force_onboarding || Settings.get!(:onboarding) do
      render_onboarding_page(conn)
    else
      render_home_page(conn)
    end
  end

  defp render_home_page(conn) do
    downloaded_media_items = where(MediaQuery.new(), ^MediaQuery.downloaded())
    volume = DiskUtils.volume_stats(Application.get_env(:pinchflat, :media_directory))
    media_item_count = Repo.aggregate(downloaded_media_items, :count, :id)
    media_item_size = Repo.aggregate(downloaded_media_items, :sum, :media_size_bytes) || 0

    pending_count = Media.pending_media_count()
    failed_count = Media.count_errored_media_items([])

    # Pending disk need: average size of downloaded items times the pending
    # count. An estimate by nature - real sizes are only known to yt-dlp.
    pending_disk_need =
      if media_item_count > 0,
        do: round(media_item_size / media_item_count * pending_count),
        else: 0

    conn
    |> render(:home,
      media_item_size: media_item_size,
      media_item_count: media_item_count,
      media_free_bytes: volume && volume.free_bytes,
      media_total_bytes: volume && volume.total_bytes,
      pending_count: pending_count,
      failed_count: failed_count,
      pending_disk_need: pending_disk_need,
      downloading_count: Media.downloading_media_item_ids() |> Enum.count(),
      recent_downloads: Media.recent_downloads(8),
      sources_health: Media.sources_health(),
      cookies_age_days: cookie_age_days(),
      cookies_present: cookies_file_present?(),
      last_backup_at: last_backup_at(),
      rate_limited: Pinchflat.RateLimit.tripped?(),
      rate_limit_seconds: Pinchflat.RateLimit.seconds_remaining(),
      yt_dlp_version: Settings.get!(:yt_dlp_version),
      yt_dlp_auto_update: auto_update_enabled?()
    )
  end

  defp cookie_age_days do
    path = Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt")

    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> div(System.os_time(:second) - mtime, 86_400)
      _ -> nil
    end
  end

  defp cookies_file_present? do
    path = Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt")

    File.exists?(path) and File.stat!(path).size > 0
  rescue
    _ -> false
  end

  # Non-raising on purpose: the backup dir can vanish or a backup can be
  # pruned between ls and stat (the nightly job rotates); neither may take
  # the home page down. Unreadable/absent entries are skipped.
  defp last_backup_at do
    backup_dir = Application.get_env(:pinchflat, :backup_directory)

    with true <- is_binary(backup_dir),
         {:ok, names} <- File.ls(backup_dir) do
      names
      |> Enum.filter(&String.ends_with?(&1, ".db"))
      |> Enum.flat_map(fn name ->
        case File.stat(Path.join(backup_dir, name), time: :posix) do
          {:ok, %{mtime: mtime}} -> [mtime]
          _ -> []
        end
      end)
      |> Enum.max(fn -> nil end)
      |> case do
        nil -> nil
        mtime -> DateTime.from_unix!(mtime)
      end
    else
      _ -> nil
    end
  end

  defp auto_update_enabled? do
    System.get_env("YT_DLP_AUTO_UPDATE", "nightly") != "off"
  end

  defp render_onboarding_page(conn) do
    Settings.set(onboarding: true)

    conn
    |> render(:onboarding_checklist,
      media_profiles_exist: Repo.exists?(MediaProfile),
      sources_exist: Repo.exists?(Source),
      layout: {Layouts, :onboarding}
    )
  end
end
