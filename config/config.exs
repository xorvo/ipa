# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ipa,
  ecto_repos: [Ipa.Repo],
  generators: [timestamp_type: :utc_datetime],
  # Editor command to open workspaces. Use "zed", "code", "cursor", etc.
  # Set to nil to disable the "Open in Editor" button
  editor_command: "zed",
  # Workspace storage path - use project directory instead of /tmp which gets cleaned by OS
  # This ensures workstream files persist across system restarts
  workspace_base_path: Path.expand("../workspaces", __DIR__)

# Configures the endpoint
config :ipa, IpaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: IpaWeb.ErrorHTML, json: IpaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ipa.PubSub,
  live_view: [signing_salt: "DbFcNUMK"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ipa: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  ipa: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
