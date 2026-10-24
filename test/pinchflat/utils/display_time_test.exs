defmodule Pinchflat.Utils.DisplayTimeTest do
  use Pinchflat.DataCase

  alias Pinchflat.Utils.DisplayTime

  # Application env is global to the VM, so this case stays synchronous and
  # every test that changes :display_timezone restores the previous value
  # in on_exit
  defp with_display_timezone(timezone, fun) do
    previous = Application.get_env(:pinchflat, :display_timezone)
    Application.put_env(:pinchflat, :display_timezone, timezone)

    on_exit(fn ->
      Application.put_env(:pinchflat, :display_timezone, previous)
    end)

    fun.()
  end

  defp without_display_timezone(fun) do
    previous = Application.get_env(:pinchflat, :display_timezone)
    Application.delete_env(:pinchflat, :display_timezone)

    on_exit(fn ->
      Application.put_env(:pinchflat, :display_timezone, previous)
    end)

    fun.()
  end

  describe "to_local/1" do
    test "converts a UTC datetime to the configured display timezone" do
      with_display_timezone("Asia/Kuala_Lumpur", fn ->
        local = DisplayTime.to_local(~U[2024-01-15 00:00:00Z])

        assert {local.year, local.month, local.day} == {2024, 1, 15}
        assert {local.hour, local.minute, local.second} == {8, 0, 0}
        assert local.utc_offset == 8 * 3600
        assert DateTime.compare(local, ~U[2024-01-15 00:00:00Z]) == :eq
      end)
    end

    test "rolls the local date into the following day" do
      with_display_timezone("Asia/Kuala_Lumpur", fn ->
        local = DisplayTime.to_local(~U[2024-01-15 20:00:00Z])

        assert {local.year, local.month, local.day} == {2024, 1, 16}
        assert local.hour == 4
      end)
    end

    test "unset configuration produces UTC" do
      without_display_timezone(fn ->
        local = DisplayTime.to_local(~U[2024-01-15 12:00:00Z])

        assert local.utc_offset == 0
        assert DateTime.compare(local, ~U[2024-01-15 12:00:00Z]) == :eq
      end)
    end

    test "blank configuration produces UTC" do
      with_display_timezone("   ", fn ->
        local = DisplayTime.to_local(~U[2024-01-15 12:00:00Z])

        assert local.time_zone == "Etc/UTC"
        assert local.utc_offset == 0
        assert DateTime.compare(local, ~U[2024-01-15 12:00:00Z]) == :eq
      end)
    end

    test "an invalid zone produces UTC without raising" do
      with_display_timezone("Mars/Olympus_Mons", fn ->
        local = DisplayTime.to_local(~U[2024-01-15 12:00:00Z])

        assert local.time_zone == "Etc/UTC"
        assert local.utc_offset == 0
        assert DateTime.compare(local, ~U[2024-01-15 12:00:00Z]) == :eq
      end)
    end

    test "nonbinary configuration produces UTC without raising" do
      with_display_timezone(:not_a_timezone, fn ->
        local = DisplayTime.to_local(~U[2024-01-15 12:00:00Z])

        assert local.time_zone == "Etc/UTC"
        assert local.utc_offset == 0
        assert DateTime.compare(local, ~U[2024-01-15 12:00:00Z]) == :eq
      end)
    end

    test "an already-zoned datetime preserves its instant" do
      with_display_timezone("Asia/Kuala_Lumpur", fn ->
        zoned = DateTime.from_naive!(~N[2024-01-15 12:00:00], "America/New_York")
        local = DisplayTime.to_local(zoned)

        assert local.time_zone == "Asia/Kuala_Lumpur"
        assert DateTime.compare(local, zoned) == :eq
      end)
    end

    test "a naive datetime is interpreted as UTC" do
      with_display_timezone("Asia/Kuala_Lumpur", fn ->
        local = DisplayTime.to_local(~N[2024-01-15 00:00:00])

        assert local.hour == 8
        assert DateTime.compare(local, ~U[2024-01-15 00:00:00Z]) == :eq
      end)
    end

    test "nil returns nil" do
      assert DisplayTime.to_local(nil) == nil
    end

    test "a DST-observing zone uses different winter and summer offsets" do
      # America/New_York: -5h in winter, -4h in summer (northern hemisphere)
      winter = DisplayTime.to_local(~U[2026-01-15 12:00:00Z], "America/New_York")
      summer = DisplayTime.to_local(~U[2026-07-15 12:00:00Z], "America/New_York")

      # tzdata reports the DST hour separately (std_offset); wall time is what
      # the viewer sees, so assert the combined offset
      total = fn z -> z.utc_offset + z.std_offset end

      assert total.(winter) == -5 * 3600
      assert total.(summer) == -4 * 3600
      # tzdata reports the DST hour via std_offset, so utc_offset alone is equal
      assert winter.zone_abbr == "EST" and summer.zone_abbr == "EDT"
    end
  end

  describe "to_local/2" do
    test "an explicit valid timezone takes precedence over configuration" do
      with_display_timezone("UTC", fn ->
        local = DisplayTime.to_local(~U[2024-01-15 00:00:00Z], "Asia/Kuala_Lumpur")

        assert local.time_zone == "Asia/Kuala_Lumpur"
        assert local.hour == 8
        assert local.utc_offset == 8 * 3600
      end)
    end

    test "an invalid explicit timezone falls back to UTC" do
      local = DisplayTime.to_local(~U[2024-01-15 00:00:00Z], "Mars/Olympus_Mons")

      assert local.utc_offset == 0
      assert DateTime.compare(local, ~U[2024-01-15 00:00:00Z]) == :eq
    end
  end

  describe "date_to_local/1" do
    test "converts to the display timezone before extracting the date" do
      with_display_timezone("America/New_York", fn ->
        # 02:00 UTC is still the previous calendar day in New York
        assert DisplayTime.date_to_local(~U[2024-01-15 02:00:00Z]) == ~D[2024-01-14]
      end)
    end

    test "handles date rollover in the display timezone" do
      with_display_timezone("Asia/Kuala_Lumpur", fn ->
        assert DisplayTime.date_to_local(~U[2024-01-15 20:30:00Z]) == ~D[2024-01-16]
      end)
    end

    test "passes dates through unchanged" do
      assert DisplayTime.date_to_local(~D[2024-01-15]) == ~D[2024-01-15]
    end

    test "nil returns nil" do
      assert DisplayTime.date_to_local(nil) == nil
    end
  end
end
