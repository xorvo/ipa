defmodule Ipa.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      IpaWeb.Telemetry,
      Ipa.Repo,
      {DNSCluster, query: Application.get_env(:ipa, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Ipa.PubSub},
      # Pod infrastructure (Registry must start before PodSupervisor)
      {Registry, keys: :unique, name: Ipa.PodRegistry},
      Ipa.PodSupervisor,
      # Start a worker by calling: Ipa.Worker.start_link(arg)
      # {Ipa.Worker, arg},
      # Start to serve requests, typically the last entry
      IpaWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ipa.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    IpaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
