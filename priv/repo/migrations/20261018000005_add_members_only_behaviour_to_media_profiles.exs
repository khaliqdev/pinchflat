defmodule Pinchflat.Repo.Migrations.AddMembersOnlyBehaviourToMediaProfiles do
  use Ecto.Migration

  def change do
    alter table(:media_profiles) do
      add :members_only_behaviour, :string, default: "include", null: false
    end
  end
end
