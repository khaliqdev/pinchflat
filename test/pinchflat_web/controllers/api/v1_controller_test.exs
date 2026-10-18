defmodule PinchflatWeb.Api.V1ControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings

  setup do
    # Ensure the single settings row exists, then set the token directly:
    # route_token is not in the Setting changeset's castable fields
    Settings.get!(:onboarding)
    Repo.update_all(Pinchflat.Settings.Setting, set: [route_token: "test-token-123"])

    :ok
  end

  describe "authorization" do
    test "returns 401 without a token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/sources")

      assert conn.status == 401
    end

    test "returns 401 with a wrong token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/sources?route_token=wrong")

      assert conn.status == 401
    end
  end

  describe "GET /api/v1/sources" do
    test "returns sources with whitelisted fields", %{conn: conn} do
      source = source_fixture(%{custom_name: "API Source"})

      conn = get(conn, ~p"/api/v1/sources?route_token=test-token-123")

      assert %{"data" => [first]} = json_response(conn, 200)
      assert first["id"] == source.id
      assert first["custom_name"] == "API Source"
      refute Map.has_key?(first, "nfo_filepath")
    end
  end

  describe "GET /api/v1/media_items" do
    test "returns media items", %{conn: conn} do
      item = media_item_fixture(%{title: "API Item"})

      conn = get(conn, ~p"/api/v1/media_items?route_token=test-token-123")

      assert %{"data" => items} = json_response(conn, 200)
      assert Enum.any?(items, &(&1["id"] == item.id))
    end

    test "filters by state=errored", %{conn: conn} do
      errored = media_item_fixture(%{title: "Errored Item", last_error: "boom"})
      _fine = media_item_fixture(%{title: "Fine Item"})

      conn = get(conn, ~p"/api/v1/media_items?state=errored&route_token=test-token-123")

      assert %{"data" => items} = json_response(conn, 200)
      ids = Enum.map(items, & &1["id"])
      assert errored.id in ids
      refute Enum.any?(items, &(&1["title"] == "Fine Item"))
    end

    test "respects the limit param", %{conn: conn} do
      Enum.each(1..3, &media_item_fixture(%{title: "Item #{&1}"}))

      conn = get(conn, ~p"/api/v1/media_items?limit=2&route_token=test-token-123")

      assert %{"data" => items} = json_response(conn, 200)
      assert length(items) == 2
    end
  end

  describe "GET /api/v1/media_items/:id" do
    test "returns one item", %{conn: conn} do
      item = media_item_fixture(%{title: "One Item"})

      conn = get(conn, ~p"/api/v1/media_items/#{item.id}?route_token=test-token-123")

      assert %{"data" => %{"id" => id, "title" => "One Item"}} = json_response(conn, 200)
      assert id == item.id
    end

    test "404s for an unknown item", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/media_items/99999999?route_token=test-token-123")

      assert conn.status == 404
    end


    test "404s for a non-numeric id", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/media_items/abc?route_token=test-token-123")

      assert conn.status == 404
    end
  end
end
