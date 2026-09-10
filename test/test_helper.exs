Logger.App.stop()
HayCluster.start_distribution()
Application.ensure_all_started(:mnesia_store, type: :temporary, mode: :serial)
# Keep the cluster-join tests fast; real joins in this suite finish in milliseconds.
Application.put_env(:mnesia_store, :join_timeout, :timer.seconds(2))

ExUnit.start()
