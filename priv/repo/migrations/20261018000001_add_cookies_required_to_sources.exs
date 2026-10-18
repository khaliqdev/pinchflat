defmodule Pinchflat.Repo.Migrations.AddCookiesRequiredToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :cookies_required, :boolean, default: false
    end
  end
end
