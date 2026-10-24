defmodule Pinchflat.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    check_and_update_timezone()
    attach_oban_telemetry()
    Logger.add_handlers(:pinchflat)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    [
      Pinchflat.PromEx,
      PinchflatWeb.Telemetry,
      Pinchflat.Repo,
      # Must be before startup tasks
      Pinchflat.Boot.PreJobStartupTasks,
      {Oban, Application.fetch_env!(:pinchflat, Oban)},
      Pinchflat.Boot.PostJobStartupTasks,
      {DNSCluster, query: Application.get_env(:pinchflat, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Pinchflat.PubSub},
      # Owns the named ETS table LiveViews and download workers read/write,
      # so it must be up before the endpoint starts rendering pages
      Pinchflat.Downloading.DownloadProgress,
      # Creates the named ETS table the in-app logs viewer reads (ROADMAP 5.1)
      # if the Logger backend hasn't already: backend gen_event callbacks run
      # inside Logger's manager process and create the table at :logger boot,
      # so whichever starts first wins (init/1 is idempotent) and a restart of
      # this child restores a vanished table. Up before the endpoint so /logs
      # never sees a missing table
      Pinchflat.Logs.LogBuffer,
      # Start the Finch HTTP client for sending emails
      {Finch, name: Pinchflat.Finch},
      # Start a worker by calling: Pinchflat.Worker.start_link(arg)
      # {Pinchflat.Worker, arg},
      # Start to serve requests, typically the last entry (except for the post-boot tasks)
      PinchflatWeb.Endpoint,
      Pinchflat.Boot.PostBootStartupTasks
    ]
    |> Supervisor.start_link(strategy: :one_for_one, name: Pinchflat.Supervisor)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PinchflatWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp attach_oban_telemetry do
    events = [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]]

    :ok = Oban.Telemetry.attach_default_logger()
    :telemetry.attach_many("job-telemetry-broadcast", events, &PinchflatWeb.Telemetry.job_state_change_broadcast/4, [])
  end

  # This has to be here (rather than runtime.exs) since the `tzdata` application
  # has to be started before we can check the timezone
  defp check_and_update_timezone do
    attempted_timezone =
      case Application.get_env(:pinchflat, :display_timezone, "UTC") do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> "UTC"
            timezone -> timezone
          end

        _ ->
          "UTC"
      end

    valid_timezone =
      if Tzdata.zone_exists?(attempted_timezone) do
        attempted_timezone
      else
        Logger.warning("Invalid timezone #{attempted_timezone}, defaulting to UTC")
        "UTC"
      end

    Application.put_env(:pinchflat, :timezone, valid_timezone)
    Application.put_env(:pinchflat, :display_timezone, valid_timezone)
  end
end
