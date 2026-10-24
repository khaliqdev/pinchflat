defmodule PinchflatWeb.CustomComponents.TabComponents do
  @moduledoc false
  use Phoenix.Component

  @doc """
  Takes a list of tabs and renders them in a tabbed layout.
  """
  slot :tab, required: true do
    attr :id, :string, required: true
    attr :title, :string, required: true
  end

  slot :tab_append, required: false

  def tabbed_layout(assigns) do
    assigns = Map.put(assigns, :first_tab_id, hd(assigns.tab).id)

    ~H"""
    <div
      x-data={"{
        openTab: getTabFromHash('#{@first_tab_id}', '#{@first_tab_id}'),
        activeClasses: 'text-primary border-primary dark:text-meta-5 dark:border-meta-5',
        inactiveClasses: 'border-transparent text-zinc-600 dark:text-bodydark'
      }"}
      @hashchange.window={"openTab = getTabFromHash(openTab, '#{@first_tab_id}')"}
      class="w-full"
    >
      <header class="flex flex-col md:flex-row md:justify-between border-b border-stroke dark:border-strokedark">
        <div class="flex flex-wrap gap-5 sm:gap-10">
          <button
            :for={tab <- @tab}
            type="button"
            @click.prevent={"openTab = setTabByName('#{tab.id}')"}
            x-bind:class={"openTab === '#{tab.id}' ? activeClasses : inactiveClasses"}
            x-bind:aria-pressed={"openTab === '#{tab.id}' ? 'true' : 'false'"}
            class="w-full border-b-2 py-4 text-sm font-medium hover:text-primary dark:hover:text-meta-5 sm:w-fit md:text-base focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 dark:focus-visible:ring-offset-boxdark"
          >
            <span class="text-xl">{tab.title}</span>
          </button>
        </div>
        <div class="mx-4 my-4 lg:my-0 flex gap-5 sm:gap-10 items-center">
          {render_slot(@tab_append)}
        </div>
      </header>
      <div class="mt-4 min-h-60 overflow-x-auto">
        <div :for={tab <- @tab} x-show={"openTab === '#{tab.id}'"} class="font-medium leading-relaxed">
          {render_slot(tab)}
        </div>
      </div>
    </div>
    """
  end
end
