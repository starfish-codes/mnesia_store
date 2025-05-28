defmodule MnesiaStore.MixProject do
  use Mix.Project

  @name "MnesiaStore"
  @version "1.1.1"
  @repo_url "https://github.com/starfish-codes/mnesia_store"

  def project do
    [
      app: :mnesia_store,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "A thin wrapper for Mnesia",
      package: package(),
      deps: deps(),
      docs: docs(),
      aliases: [
        test: "test --no-start"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :mnesia]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:highlander, "~> 0.2.1"},
      {:hay_cluster, "~> 1.0", only: [:test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev], runtime: false}
    ]
  end

  defp package do
    [
      links: %{"GitHub" => @repo_url},
      licenses: ["MIT"]
    ]
  end

  defp docs do
    [
      source_ref: "v#{@version}",
      source_url: @repo_url,
      main: @name
    ]
  end
end
