import Config

config :wraith,
  store: Wraith.Store.Memory,
  clock: false,
  kiro_runtime: Wraith.Kiro.Runtime.Fake,
  acp_client: Wraith.Kiro.ACP.Fake,
  kiro_key_verifier: Wraith.FakeKiroKeyVerifier

config :wraith, Wraith.Mailer, adapter: Swoosh.Adapters.Test
config :wraith, Wraith.Uploads, adapter: Wraith.Uploads.Local, root: "tmp/test_uploads"
config :swoosh, :api_client, false

# fast hashing in tests
config :bcrypt_elixir, log_rounds: 4

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :wraith, WraithWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "hxc+KFJk994x7emME5J85T23dmEfEE/xrJiQV9zAF/dR1HbcbvE1ZlUHPiuIp7pc",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
