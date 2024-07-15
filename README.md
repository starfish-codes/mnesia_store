# MnesiaStore

A thin wrapper for Mnesia.

- Uses `:ram_copies` only
- Tries to copy tables on all available nodes

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `mnesia_store` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mnesia_store, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/mnesia_store>.

