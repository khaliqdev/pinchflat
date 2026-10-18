defmodule Pinchflat.Repo.Migrations.AddDefaultThemeToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :default_theme, :string, default: "dark", null: false
    end
  end
end
