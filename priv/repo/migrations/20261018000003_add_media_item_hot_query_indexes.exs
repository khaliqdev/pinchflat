defmodule Pinchflat.Repo.Migrations.AddMediaItemHotQueryIndexes do
  use Ecto.Migration

  def change do
    # Serves the pending/downloaded aggregate scans that run on every sources
    # index page load and library-wide status queries (upstream #591)
    create index(:media_items, [:source_id, :media_filepath, :prevent_download])
  end
end
