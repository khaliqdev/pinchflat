defmodule Pinchflat.Utils.DiskUtilsTest do
  use Pinchflat.DataCase

  alias Pinchflat.Utils.DiskUtils

  describe "free_bytes/1" do
    test "returns a positive byte count for an existing path" do
      assert free = DiskUtils.free_bytes("/")
      assert is_integer(free)
      assert free > 0
    end

    test "returns nil for a missing path" do
      assert is_nil(DiskUtils.free_bytes("/definitely/not/a/real/path-#{System.unique_integer()}"))
    end
  end
end
