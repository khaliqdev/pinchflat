defmodule Pinchflat.Repo.Migrations.AddExternalDeleteBehaviourToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :external_delete_behaviour, :string, default: "prevent_download", null: false
    end
  end
end
