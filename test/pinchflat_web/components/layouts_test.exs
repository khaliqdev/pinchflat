defmodule PinchflatWeb.Components.LayoutsTest do
  use PinchflatWeb.ConnCase

  import Phoenix.Component

  import Phoenix.LiveViewTest

  alias PinchflatWeb.Layouts

  describe "sidebar_submenu/1" do
    test "renders a native disclosure button with an expanded binding" do
      html = render_submenu("/settings")

      assert html =~ ~s(<button type="button")
      assert html =~ ~s(x-on:click="selected = !selected")
      assert html =~ ~s(x-bind:aria-expanded="selected ? 'true' : 'false'")
      assert html =~ "w-full text-left"
      assert html =~
               "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 dark:focus-visible:ring-offset-boxdark"
    end

    test "submenu is initially selected when current_path matches a submenu href" do
      html = render_submenu("/settings")

      assert html =~ "{ selected: true }"
      assert html =~ ~s(x-cloak x-show="selected")
      assert html =~ "Settings"
    end

    test "submenu is not initially selected when current_path matches nothing" do
      html = render_submenu("/sources")

      assert html =~ "{ selected: false }"
    end
  end

  defp render_submenu(current_path) do
    render_component(fn assigns ->
      ~H"""
      <Layouts.sidebar_submenu icon="hero-cog-6-tooth" text="Config" current_path={@current_path}>
        <:submenu text="Settings" href="/settings" />
        <:submenu text="Logs" href="/logs" />
      </Layouts.sidebar_submenu>
      """
    end, %{current_path: current_path})
  end
end
