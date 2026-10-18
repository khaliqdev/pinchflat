defmodule Pinchflat.Repo.Migrations.AddFailureNotificationSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :failure_notifications, :boolean, default: false, null: false
      add :failure_digest_cursor, :utc_datetime
    end
  end
end
