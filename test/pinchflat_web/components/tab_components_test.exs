defmodule PinchflatWeb.Components.TabComponentsTest do
  use PinchflatWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias PinchflatWeb.CustomComponents.TabComponents

  describe "tabbed_layout/1" do
    test "renders native buttons with pressed bindings" do
      html = render_tabs()

      assert html =~ ~s(type="button")
      assert html =~ "setTabByName(&#39;downloads&#39;)"
      assert html =~ "setTabByName(&#39;history&#39;)"
      assert html =~ ~s(x-bind:aria-pressed)
      assert html =~ "openTab === &#39;downloads&#39;"
      assert html =~ "openTab === &#39;history&#39;"
    end

    test "keeps the hash-driven open tab expressions" do
      html = render_tabs()

      assert html =~ "getTabFromHash(&#39;downloads&#39;, &#39;downloads&#39;)"
      assert html =~ "@hashchange.window=\"openTab = getTabFromHash(openTab, &#39;downloads&#39;)\""
      assert html =~ ~s(x-show="openTab === &#39;downloads&#39;")
    end

    test "no href anchors remain" do
      html = render_tabs()

      refute html =~ ~s(href="#")
      refute html =~ "<a "
    end
  end

  defp render_tabs do
    render_component(fn assigns ->
      ~H"""
      <TabComponents.tabbed_layout>
        <:tab id="downloads" title="Downloads">Downloads content</:tab>
        <:tab id="history" title="History">History content</:tab>
      </TabComponents.tabbed_layout>
      """
    end)
  end
end
