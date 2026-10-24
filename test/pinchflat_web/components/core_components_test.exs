defmodule PinchflatWeb.Components.CoreComponentsTest do
  use PinchflatWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PinchflatWeb.CoreComponents

  @focus_recipe "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 dark:focus-visible:ring-offset-boxdark"

  describe "toggle input" do
    test "renders a native switch button with a bound checked state" do
      html = render_toggle(%{value: "true"})

      assert html =~ ~s(type="button")
      assert html =~ ~s(role="switch")
      assert html =~ ~s(aria-label="Use Fast Indexing")
      assert html =~ ~s(x-bind:aria-checked)
      assert html =~ "enabled ? 'true' : 'false'"
      assert html =~ "{ enabled: true }"
    end

    test "renders the unchecked state" do
      html = render_toggle(%{value: "false"})

      assert html =~ "{ enabled: false }"
    end

    test "label targets the switch button" do
      html = render_toggle(%{value: "true"})

      assert html =~ ~s(for="fast_index-button")
    end

    test "hidden input keeps its original id and name" do
      html = render_toggle(%{value: "true"})

      assert html =~ ~s(id="fast_index")
      assert html =~ ~s(name="source[fast_index]")
      assert html =~ ~s(x-bind:value="enabled")
    end

    test "supplied attributes stay on the hidden input" do
      html = render_toggle(%{value: "true", rest_attrs: [required: true]})

      assert html =~ ~s(required)
    end

    test "click expression dispatches the change event for the hidden input" do
      html = render_toggle(%{value: "true"})

      assert html =~ "dispatchFor(&#39;fast_index&#39;, &#39;change&#39;)"
    end

    test "disabled attributes reach the switch instead of the hidden input" do
      html =
        render_toggle(%{
          value: "true",
          disabled: true,
          rest_attrs: [disabled: true, "x-bind:disabled": "fastIndexingEnabled == true"]
        })

      assert html =~ ~r/<button[^>]*disabled/
      assert html =~ ~r/<button[^>]*x-bind:disabled="fastIndexingEnabled == true"/
    end

    test "optional toggle_click reaches the native switch button, not the wrapper" do
      html = render_toggle(%{value: "true", toggle_click: "show_modal('upgrade-modal')"})

      assert html =~ ~r/<button[^>]*phx-click="show_modal\(&#39;upgrade-modal&#39;\)"/
      refute html =~ ~s(<div phx-click)
    end

    test "renders the track and thumb recipes with the focus recipe" do
      html = render_toggle(%{value: "true"})

      assert html =~ "block h-8 w-14 rounded-full bg-black"
      assert html =~ "rounded-full bg-white transition"
      assert html =~ @focus_recipe
    end
  end

  describe "old_table row actions" do
    test "row click handler is on a button, not the cell" do
      html = render_old_table(%{row_click: fn _row -> "row-clicked" end})

      assert html =~ ~s(<td class="relative p-0 hover:cursor-pointer">)
      assert html =~ ~s(phx-click="row-clicked")
      assert html =~ @focus_recipe
    end

    test "no button is rendered without row_click" do
      html = render_old_table(%{row_click: nil})

      assert html =~ ~s(class="relative p-0)
      assert html =~ "row-1"
      refute html =~ ~s(type="button")
      refute html =~ "phx-click"
    end
  end

  defp render_toggle(assigns) do
    assigns =
      assigns
      |> Map.put(:rest, Map.get(assigns, :rest_attrs, []))
      |> Map.put(:toggle_click, Map.get(assigns, :toggle_click))

    render_component(
      fn assigns ->
        ~H"""
        <PinchflatWeb.CoreComponents.input
          type="toggle"
          id="fast_index"
          name="source[fast_index]"
          value={@value}
          label="Use Fast Indexing"
          label_suffix="(pro)"
          toggle_click={@toggle_click}
          {@rest}
        />
        """
      end,
      assigns
    )
  end

  defp render_old_table(assigns) do
    render_component(fn assigns ->
      ~H"""
      <PinchflatWeb.CoreComponents.old_table id="rows" rows={@rows} row_click={@row_click}>
        <:col :let={row} label="Name">{row.name}</:col>
      </PinchflatWeb.CoreComponents.old_table>
      """
    end, Map.put(assigns, :rows, [%{name: "row-1"}]))
  end
end
