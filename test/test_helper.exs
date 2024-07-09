Logger.App.stop()
HayCluster.start_distribution()
Application.ensure_all_started(:mnesia_store, type: :temporary, mode: :serial)

ExUnit.start()
