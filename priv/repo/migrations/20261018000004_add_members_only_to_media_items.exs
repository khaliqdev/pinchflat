defmodule Pinchflat.Repo.Migrations.AddMembersOnlyToMediaItems do
  use Ecto.Migration

  def change do
    add_members_only_column()

    create index(:media_items, [:members_only])
  end

  def add_members_only_column do
    alter table(:media_items) do
      add :members_only, :boolean, default: false, null: false
    end
  end
end
