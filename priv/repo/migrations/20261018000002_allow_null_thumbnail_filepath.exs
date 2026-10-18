defmodule Pinchflat.Repo.Migrations.AllowNullThumbnailFilepath do
  use Ecto.Migration

  # SQLite cannot ALTER COLUMN constraints, so this rebuilds the table.
  # A failed thumbnail download must not invalidate the media item save
  # (it caused a crash-loop where the whole download was retried forever,
  # see upstream issue #889)
  #
  # The old table is dropped BEFORE creating the new unique index because
  # SQLite keeps index names attached to the renamed table.
  def up do
    flush()

    rename table(:media_metadata), to: table("media_metadata_old")

    create table(:media_metadata) do
      add :metadata_filepath, :string, null: false
      add :thumbnail_filepath, :string
      add :media_item_id, references(:media_items, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    execute("""
    INSERT INTO media_metadata (id, metadata_filepath, thumbnail_filepath, media_item_id, inserted_at, updated_at)
    SELECT id, metadata_filepath, thumbnail_filepath, media_item_id, inserted_at, updated_at
    FROM media_metadata_old
    """)

    drop table("media_metadata_old")

    create unique_index(:media_metadata, [:media_item_id])
  end

  def down do
    flush()

    rename table(:media_metadata), to: table("media_metadata_new")

    create table(:media_metadata) do
      add :metadata_filepath, :string, null: false
      add :thumbnail_filepath, :string, null: false
      add :media_item_id, references(:media_items, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    execute("""
    INSERT INTO media_metadata (id, metadata_filepath, thumbnail_filepath, media_item_id, inserted_at, updated_at)
    SELECT id, metadata_filepath, thumbnail_filepath, media_item_id, inserted_at, updated_at
    FROM media_metadata_new
    """)

    drop table("media_metadata_new")

    create unique_index(:media_metadata, [:media_item_id])
  end
end
