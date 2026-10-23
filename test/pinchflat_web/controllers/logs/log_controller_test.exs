defmodule PinchflatWeb.Logs.LogControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Logs.LogBuffer

  # The app's supervision tree already started the LogBuffer backend; tests
  # run at logger level :critical, so seeding goes through record/3.
  # Reset HERE, synchronously - an on_exit reset runs as a separate task that
  # can interleave with the next test and wipe rows it just seeded
  setup do
    LogBuffer.reset!()
  end

  describe "GET /logs" do
    test "renders the logs page with the live viewer", %{conn: conn} do
      LogBuffer.record(:info, "rendered through the page shell", %{})

      conn = get(conn, ~p"/logs")

      assert html_response(conn, 200) =~ "Logs"
      assert html_response(conn, 200) =~ "rendered through the page shell"
    end
  end

  describe "GET /logs/download" do
    test "exports the last N buffered lines as plain text", %{conn: conn} do
      Enum.each(1..10, &LogBuffer.record(:info, "export line #{&1}", %{}))

      conn = get(conn, ~p"/logs/download?lines=5")

      assert response(conn, 200) =~ "export line 10"
      assert response(conn, 200) =~ "export line 6"
      refute response(conn, 200) =~ "export line 5"
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type |> String.split(";") |> List.first() == "text/plain"
    end

    test "defaults to the last 1,000 lines for a missing or junk param", %{conn: conn} do
      Enum.each(1..5, &LogBuffer.record(:info, "default window line #{&1}", %{}))

      conn = get(conn, ~p"/logs/download")

      assert response(conn, 200) =~ "default window line 1"
      assert response(conn, 200) =~ "default window line 5"

      junk_conn = get(conn, ~p"/logs/download?lines=nope")

      assert response(junk_conn, 200) =~ "default window line 1"
    end

    test "exports the raw buffer - level filtering is the viewer's job, not the export's", %{conn: conn} do
      LogBuffer.record(:debug, "debug export line", %{})
      LogBuffer.record(:info, "info export line", %{})

      conn = get(conn, ~p"/logs/download?lines=10")

      assert response(conn, 200) =~ "info export line"
      assert response(conn, 200) =~ "debug export line"
    end
  end
end
