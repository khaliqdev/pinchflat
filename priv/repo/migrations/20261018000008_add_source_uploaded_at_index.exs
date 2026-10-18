defmodule Pinchflat.Repo.Migrations.AddSourceUploadedAtIndex do
  use Ecto.Migration

  def change do
    # Serves the per-insert min/max upload_date_index aggregate, which filters
    # on (source, uploaded_at-day). Without it, first-indexing a large channel
    # degrades to O(N^2) row scans
    create index(:media_items, [:source_id, :uploaded_at])
  end
end
