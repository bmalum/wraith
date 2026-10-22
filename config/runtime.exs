import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/wraith start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :wraith, WraithWeb.Endpoint, server: true
end

config :wraith, WraithWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# ---- storage -------------------------------------------------------------------
#
#   WRAITH_STORE=memory            in-process ETS (dev default, nothing persists)
#   WRAITH_STORE=dynamo            DynamoDB single table (deployed default)
#   WRAITH_STORE=postgres          PostgreSQL, one table — DATABASE_URL=postgres://u:p@host/db
#   WRAITH_STORE=dsql              Aurora DSQL — DSQL_ENDPOINT=<cluster>.dsql.<region>.on.aws (IAM auth)
#   WRAITH_TABLE=wraith            table name (DynamoDB) / items (SQL)
#   DYNAMO_ENDPOINT=http://localhost:8000   DynamoDB Local
#   AWS_REGION / AWS_PROFILE       the usual credential chain (ex_aws)
# Tests run on the in-memory store. `WRAITH_TEST_DYNAMO=http://127.0.0.1:8000 mix test`
# runs the suite on DynamoDB Local, `WRAITH_TEST_POSTGRES=postgres://postgres:postgres@127.0.0.1:5432/wraith_test`
# on PostgreSQL — the places the real adapters are exercised.
if config_env() == :test and System.get_env("WRAITH_TEST_POSTGRES") do
  config :wraith, store: Wraith.Store.SQL

  config :wraith, Wraith.Store.SQL,
    dialect: :postgres,
    url: System.get_env("WRAITH_TEST_POSTGRES"),
    table: "items",
    pool_size: 5
end

if config_env() == :test and System.get_env("WRAITH_TEST_DYNAMO") do
  config :wraith, store: Wraith.Store.Dynamo
  config :wraith, Wraith.Store.Dynamo, table: System.get_env("WRAITH_TABLE", "wraith")
  uri = URI.parse(System.get_env("WRAITH_TEST_DYNAMO"))

  config :ex_aws, :dynamodb,
    scheme: uri.scheme <> "://",
    host: uri.host,
    port: uri.port,
    region: "eu-central-1"

  config :ex_aws, access_key_id: "local", secret_access_key: "local", region: "eu-central-1"
end

if config_env() != :test do
  region = System.get_env("AWS_REGION", "eu-central-1")

  store =
    case System.get_env("WRAITH_STORE", if(config_env() == :dev, do: "memory", else: "dynamo")) do
      "memory" -> Wraith.Store.Memory
      "postgres" -> Wraith.Store.SQL
      "dsql" -> Wraith.Store.SQL
      _ -> Wraith.Store.Dynamo
    end

  config :wraith, store: store
  config :wraith, Wraith.Store.Dynamo, table: System.get_env("WRAITH_TABLE", "wraith")

  case System.get_env("WRAITH_STORE") do
    "postgres" ->
      config :wraith, Wraith.Store.SQL,
        dialect: :postgres,
        url: System.get_env("DATABASE_URL") || raise("WRAITH_STORE=postgres needs DATABASE_URL"),
        table: System.get_env("WRAITH_TABLE", "items"),
        ssl: System.get_env("DATABASE_SSL") in ["true", "1"],
        pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

    "dsql" ->
      config :wraith, Wraith.Store.SQL,
        dialect: :dsql,
        hostname:
          System.get_env("DSQL_ENDPOINT") || raise("WRAITH_STORE=dsql needs DSQL_ENDPOINT"),
        username: System.get_env("DSQL_USER", "admin"),
        database: "postgres",
        region: region,
        table: System.get_env("WRAITH_TABLE", "items"),
        pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

    _ ->
      :ok
  end

  config :ex_aws, region: region

  if profile = System.get_env("AWS_PROFILE") do
    config :ex_aws,
      access_key_id: [{:awscli, profile, 30}, :instance_role],
      secret_access_key: [{:awscli, profile, 30}, :instance_role]
  end

  if endpoint = System.get_env("DYNAMO_ENDPOINT") do
    uri = URI.parse(endpoint)

    config :ex_aws, :dynamodb,
      scheme: uri.scheme <> "://",
      host: uri.host,
      port: uri.port,
      region: region

    # DynamoDB Local accepts any static key
    config :ex_aws,
      access_key_id: System.get_env("AWS_ACCESS_KEY_ID", "local"),
      secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY", "local")
  end

  # ---- the Kiro studio (agent on a Lambda MicroVM) --------------------------------
  #
  #   WRAITH_MICROVM_IMAGE_ARN, WRAITH_MICROVM_IMAGE_VERSION,
  #   WRAITH_MICROVM_EXECUTION_ROLE_ARN, WRAITH_JOURNAL_BUCKET
  #   unset = offline fake runtime (the studio answers with a scripted agent)
  case System.get_env("WRAITH_MICROVM_IMAGE_ARN") do
    nil ->
      config :wraith,
        kiro_runtime: Wraith.Kiro.Runtime.Fake,
        acp_client: Wraith.Kiro.ACP.Fake

    arn ->
      config :wraith,
        kiro_runtime: Wraith.Kiro.Runtime.MicroVM,
        acp_client: Wraith.Kiro.ACP

      config :wraith, Wraith.Kiro.Runtime.MicroVM,
        image_arn: arn,
        image_version: System.get_env("WRAITH_MICROVM_IMAGE_VERSION"),
        execution_role_arn: System.get_env("WRAITH_MICROVM_EXECUTION_ROLE_ARN"),
        journal_bucket: System.get_env("WRAITH_JOURNAL_BUCKET"),
        region: region
  end

  if from = System.get_env("MAIL_FROM"), do: config(:wraith, mail_from: from)

  # ---- uploads ---------------------------------------------------------------------
  #   UPLOADS_BUCKET=my-bucket [UPLOADS_PREFIX=uploads] [UPLOADS_URL=https://cdn.example.com]
  #   unset = local disk (UPLOADS_DIR, default priv/uploads), served at /uploads
  case System.get_env("UPLOADS_BUCKET") do
    nil ->
      config :wraith, Wraith.Uploads,
        adapter: Wraith.Uploads.Local,
        root: System.get_env("UPLOADS_DIR")

    bucket ->
      config :wraith, Wraith.Uploads,
        adapter: Wraith.Uploads.S3,
        bucket: bucket,
        prefix: System.get_env("UPLOADS_PREFIX", "uploads"),
        public_url: System.get_env("UPLOADS_URL")
  end

  if key = System.get_env("KIRO_API_KEY") do
    config :wraith, kiro_api_key: key
  end
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :wraith, WraithWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/wraith_web/router\.ex$"E,
        ~r"lib/wraith_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # every absolute URL — feeds, sitemap, newsletter links, the API — is built
  # from this; a forgotten variable would silently point them all at example.com
  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Set it to the public hostname of the site, e.g. blog.example.com
      """

  # Rate limits key on the client IP. Behind a load balancer the socket address
  # is the balancer, and X-Forwarded-For is client-controlled except for the
  # hops our own proxies append. Say how many proxies sit in front (1 for an
  # ALB); 0 (the default) trusts only the socket address.
  config :wraith, :trusted_proxies, String.to_integer(System.get_env("TRUSTED_PROXIES") || "0")

  # Secrets at rest (Stripe keys, the Kiro key) are encrypted with this, not
  # with SECRET_KEY_BASE, so cookies can be rotated without losing them.
  config :wraith, Wraith.Vault,
    key:
      System.get_env("WRAITH_VAULT_KEY") ||
        raise("""
        environment variable WRAITH_VAULT_KEY is missing.
        Generate one with: mix phx.gen.secret
        It encrypts stored secrets (Stripe, Kiro); changing it makes them unreadable.
        """)

  config :wraith, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :wraith, WraithWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      # see config/prod.exs: HTTP/2 stays off while bandit's advisory is open
      http_2_options: [enabled: false]
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :wraith, WraithWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :wraith, WraithWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
