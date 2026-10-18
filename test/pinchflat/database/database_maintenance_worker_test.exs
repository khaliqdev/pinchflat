defmodule Pinchflat.Database.DatabaseMaintenanceWorkerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Database.DatabaseMaintenanceWorker

  describe "perform/1" do
    test "runs maintenance without error" do
      assert :ok = perform_job(DatabaseMaintenanceWorker, %{})
    end
  end
end
