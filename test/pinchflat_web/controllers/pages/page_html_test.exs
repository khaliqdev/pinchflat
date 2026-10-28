defmodule PinchflatWeb.Pages.PageHTMLTest do
  use ExUnit.Case, async: false

  alias PinchflatWeb.Pages.PageHTML

  describe "days_ago/2" do
    setup do
      previous = Application.get_env(:pinchflat, :display_timezone)
      Application.put_env(:pinchflat, :display_timezone, "Asia/Tokyo")

      on_exit(fn ->
        if previous, do: Application.put_env(:pinchflat, :display_timezone, previous)
      end)

      :ok
    end

    test "nil-safe for legacy items" do
      assert PageHTML.days_ago(nil) == "unknown"
    end

    test "compares local dates on both sides around midnight (UTC+9)" do
      # 20:00Z on the 28th is already the 29th in Tokyo; a download from
      # 05:00Z on the 28th is YESTERDAY locally even though its UTC date
      # equals today's UTC date
      now = ~U[2026-10-28 20:00:00Z]
      downloaded = ~U[2026-10-28 05:00:00Z]

      assert PageHTML.days_ago(downloaded, now) == "yesterday"
    end

    test "a just-finished download is today" do
      now = ~U[2026-10-28 20:00:00Z]

      assert PageHTML.days_ago(~U[2026-10-28 20:00:00Z], now) == "today"
    end

    test "past a week shows the ISO date" do
      now = ~U[2026-10-28 20:00:00Z]

      assert PageHTML.days_ago(~U[2026-10-01 12:00:00Z], now) == "2026-10-01"
    end
  end
end
