# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :wraith,
  generators: [timestamp_type: :utc_datetime],
  # the single table; `Wraith.Store.Memory` in test, `Wraith.Store.Dynamo` deployed
  store: Wraith.Store.Dynamo,
  kiro_runtime: Wraith.Kiro.Runtime.MicroVM,
  acp_client: Wraith.Kiro.ACP,
  kiro_key_verifier: Wraith.Kiro.Key.Remote

config :wraith, Wraith.Store.Dynamo, table: "wraith"

# ex_aws rides on Req (no hackney) and Jason
config :ex_aws,
  http_client: ExAws.Request.Req,
  json_codec: Jason,
  region: "eu-central-1"

# Configure the endpoint
config :wraith, WraithWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: WraithWeb.ErrorHTML, json: WraithWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Wraith.PubSub,
  live_view: [signing_salt: "DCQ8T/Qt"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  wraith: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  wraith: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
