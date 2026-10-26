defmodule PinchflatWeb.Components.ButtonComponentsTest do
  use PinchflatWeb.ConnCase

  import Phoenix.Component

  import Phoenix.LiveViewTest

  alias PinchflatWeb.CustomComponents.ButtonComponents

  describe "button_dropdown/1" do
    test "renders a native trigger button with the unchanged toggle expression" do
      html = render_dropdown()

      assert html =~ ~s(<button type="button" x-ref="dropdownTrigger")
      assert html =~ ~s(x-on:click.prevent="dropdownOpen = !dropdownOpen")
    end

    test "adverts expanded state and the focus recipe on the trigger" do
      html = render_dropdown()

      assert html =~ ~s(x-bind:aria-expanded="dropdownOpen ? 'true' : 'false'")

      assert html =~
               "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 dark:focus-visible:ring-offset-boxdark"
    end

    test "escape closes the dropdown and returns focus to the trigger" do
      html = render_dropdown()

      assert html =~ "x-on:keydown.escape.stop=\"dropdownOpen = false; $refs.dropdownTrigger.focus()\""
    end

    test "option wrapper is a noninteractive div and no menu role is advertised" do
      html = render_dropdown()

      assert html =~ ~s(<div class="flex px-5 py-2 font-medium text-bodydark2 hover:text-white cursor-pointer">)

      refute html =~ "<span class=\"flex px-5 py-2)"
      refute html =~ ~s(role="menu")
    end
  end

  defp render_dropdown do
    render_component(fn assigns ->
      ~H"""
      <ButtonComponents.button_dropdown text="Actions">
        <:option><a href="/sources/1">Option A</a></:option>
      </ButtonComponents.button_dropdown>
      """
    end)
  end
end
