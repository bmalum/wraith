defmodule Wraith.MixProject do
  use Mix.Project

  def project do
    [
      app: :wraith,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      # docs: `mix wraith.site` builds them into _site/docs with the guides
      name: "Wraith",
      source_url: "https://github.com/bmalum/wraith",
      homepage_url: "https://bmalum.github.io/wraith/",
      docs: &docs/0
    ]
  end

  # A function, not a list: `mix wraith.site` writes the guides into
  # _build/guides first and ex_doc reads this afterwards. Plain `mix docs`
  # (no guides generated) falls back to the README.
  @guides ~w(overview run-it themes widgets agent-studio mcp-server mcp-tools
             storage-layout security deploy tests)
  defp docs do
    generated =
      for g <- @guides, File.exists?("_build/guides/#{g}.md"), do: "_build/guides/#{g}.md"

    [
      main: if(generated == [], do: "readme", else: "overview"),
      extras: if(generated == [], do: ["README.md"], else: generated),
      groups_for_extras: [
        Guides: ~r{/(overview|run-it|themes|widgets|agent-studio|deploy)\.md$},
        Reference: ~r{/(mcp-server|mcp-tools|storage-layout|security|tests)\.md$}
      ],
      groups_for_modules: [
        "Content & publishing": [
          Wraith.Content,
          Wraith.Markdown,
          Wraith.Embed,
          Wraith.Search,
          Wraith.Newsletter,
          Wraith.Comments,
          Wraith.Images,
          Wraith.Uploads,
          Wraith.Uploads.Local,
          Wraith.Uploads.S3,
          Wraith.Slug,
          Wraith.Ghost
        ],
        "Members & billing": [Wraith.Members, Wraith.Billing, Wraith.Billing.API, Wraith.Tokens],
        "Staff & access": [
          Wraith.Accounts,
          Wraith.Policy,
          Wraith.ApiKeys,
          Wraith.Vault,
          Wraith.RateLimit,
          Wraith.SafeHTTP
        ],
        Widgets: ~r/^Wraith\.Widgets/,
        "Agents & MCP": [Wraith.Tools, ~r/^Wraith\.Studio/, ~r/^Wraith\.Kiro/],
        Storage: ~r/^Wraith\.Store/,
        Themes: [WraithWeb.Theme, WraithWeb.Theme.Layout, ~r/^WraithWeb\.Themes/],
        "Web: public site": [
          ~r/^WraithWeb\.Site\./,
          WraithWeb.SiteComponents,
          WraithWeb.SiteHooks
        ],
        "Web: admin": ~r/^WraithWeb\.Admin\./,
        "Web: APIs & plumbing": ~r/^WraithWeb\./
      ],
      source_ref: "main",
      logo: "site/assets/mark.svg",
      favicon: "site/assets/mark.svg",
      assets: %{"site/assets/docs" => "assets"},
      before_closing_head_tag: &docs_head/1,
      formatters: ["html"]
    ]
  end

  # the docs share the site's two typefaces
  defp docs_head(:html),
    do: ~s(<link rel="stylesheet" href="assets/docs.css">)

  defp docs_head(_), do: ""

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Wraith.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      # API docs + guides for the project site (`mix wraith.site`)
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # the one HTTP client (ex_aws rides on it too)
      {:req, "~> 0.5"},
      # DynamoDB single table
      {:ex_aws, "~> 2.7"},
      {:ex_aws_dynamo, "~> 4.2"},
      # Lua-scripted widgets
      {:luerl, "~> 1.5"},
      # markdown → HTML (sanitised)
      {:mdex, "~> 0.14"},
      # code block syntax highlighting for mdex
      {:lumis, "~> 0.10"},
      {:lumis_wasm_bundle_web, "~> 0.1"},
      {:lumis_wasm_bundle_backend, "~> 0.1"},
      {:lumis_wasm_elixir, "~> 0.26"},
      {:lumis_wasm_bash, "~> 0.26"},
      {:lumis_wasm_yaml, "~> 0.26"},
      {:lumis_wasm_markdown, "~> 0.26"},
      # ACP (JSON-RPC over WebSocket) to Kiro Agent Servers
      {:mint_web_socket, "~> 1.0"},
      # owner password
      {:bcrypt_elixir, "~> 3.3"},
      # the SQL store adapter (PostgreSQL and Aurora DSQL)
      {:postgrex, "~> 0.22"},
      # uploads to S3
      {:image, "~> 0.72.0"},
      {:ex_aws_s3, "~> 2.5"},
      # mail: newsletters, magic links, password resets (SES in prod via ex_aws)
      # the SES adapter builds raw MIME with gen_smtp's :mimemail
      {:gen_smtp, "~> 1.2"},
      {:swoosh, "~> 1.29"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  # Recent macOS kills the freshly downloaded tailwind binary (SIGKILL, exit
  # 137) until it carries a signature; an ad-hoc one is enough.
  defp sign_tailwind(_args) do
    if match?({:unix, :darwin}, :os.type()) do
      for bin <-
            Path.wildcard(
              Path.join(Mix.Project.build_path() |> Path.dirname(), "tailwind-macos-*")
            ) do
        System.cmd("codesign", ["-s", "-", "-f", bin], stderr_to_stdout: true)
      end
    end

    :ok
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        &sign_tailwind/1
      ],
      "assets.build": ["compile", "tailwind wraith", "esbuild wraith"],
      "assets.deploy": [
        "tailwind wraith --minify",
        "esbuild wraith --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
