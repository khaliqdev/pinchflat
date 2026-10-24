defmodule PinchflatWeb.Components.TableComponentsTest do
  use PinchflatWeb.ConnCase

  import Phoenix.Component

  import Phoenix.LiveViewTest

  alias PinchflatWeb.CustomComponents.TableComponents

  describe "sortable headers" do
    test "sortable header contains a button with the existing event and payload" do
      html = render_table(%{sort_key: "custom_name", sort_direction: :asc})

      assert html =~ ~s(<button type="button" phx-click="sort_update" phx-value-sort_key="custom_name")

      assert html =~
               "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 dark:focus-visible:ring-offset-boxdark"
    end

    test "active ascending column is marked ascending" do
      html = render_table(%{sort_key: "custom_name", sort_direction: :asc})

      assert html =~ ~s(aria-sort="ascending")
    end

    test "active descending column is marked descending" do
      html = render_table(%{sort_key: "custom_name", sort_direction: :desc})

      assert html =~ ~s(aria-sort="descending")
    end

    test "inactive sortable column is marked none" do
      html = render_table(%{sort_key: "title", sort_direction: :asc})

      assert html =~ ~s(aria-sort="none")
    end

    test "unsortable header does not acquire a button or aria-sort" do
      html =
        render_component(fn assigns ->
          ~H"""
          <TableComponents.table rows={@rows}>
            <:col :let={row} label="Name">{row.name}</:col>
          </TableComponents.table>
          """
        end, %{rows: [%{name: "row-1"}]})

      assert html =~ "Name"
      refute html =~ "<button"
      refute html =~ "aria-sort"
      refute html =~ "sort_update"
    end
  end

  describe "live_pagination_controls/1" do
    test "renders a labeled nav with native buttons and existing direction payloads" do
      html = render_pagination(2, 3)

      assert html =~ ~s(<nav aria-label="Pagination">)
      assert html =~ ~s(<button type="button" aria-label="Previous page")
      assert html =~ ~s(<button type="button" aria-label="Next page")
      assert html =~ ~s(phx-click="page_change")
      assert html =~ ~s(phx-value-direction="dec")
      assert html =~ ~s(phx-value-direction="inc")
    end

    test "first page disables the previous button and its event" do
      html = render_pagination(1, 3)

      assert html =~ ~s(aria-label="Previous page" disabled)
      assert html |> String.split("page_change") |> length() == 2
    end

    test "last page disables the next button" do
      html = render_pagination(3, 3)

      assert html =~ ~s(aria-label="Next page" disabled)
    end

    test "middle page enables both buttons" do
      html = render_pagination(2, 3)

      refute html =~ "disabled"
    end
  end

  defp render_table(assigns) do
    render_component(fn assigns ->
      ~H"""
      <TableComponents.table rows={@rows} sort_key={@sort_key} sort_direction={@sort_direction}>
        <:col :let={row} label="Name" sort_key="custom_name">{row.name}</:col>
        <:col :let={row} label="Title" sort_key="title">{row.name}</:col>
      </TableComponents.table>
      """
    end, Map.put(assigns, :rows, [%{name: "row-1"}]))
  end

  defp render_pagination(page_number, total_pages) do
    render_component(&TableComponents.live_pagination_controls/1,
      page_number: page_number,
      total_pages: total_pages
    )
  end
end
