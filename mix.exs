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
      listeners: [Phoenix.CodeReloader]
    ]
  end

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
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
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
