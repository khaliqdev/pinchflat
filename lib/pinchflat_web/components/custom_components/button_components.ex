defmodule PinchflatWeb.CustomComponents.ButtonComponents do
  @moduledoc false
  use Phoenix.Component, global_prefixes: ~w(x-)

  alias PinchflatWeb.CoreComponents
  alias PinchflatWeb.CustomComponents.TextComponents

  @doc """
  Render a button

  ## Examples

      <.button color="bg-primary" rounding="rounded-sm">
        <span>Click me</span>
      </.button>
  """
  attr :color, :string, default: "bg-primary"
  attr :rounding, :string, default: "rounded-sm"
  attr :class, :string, default: ""
  attr :type, :string, default: "submit"
  attr :disabled, :boolean, default: false
  attr :rest, :global

  slot :inner_block, required: true

  @button_color_classes %{
    "bg-primary" => "border-transparent bg-primary text-white enabled:hover:bg-opacity-90",
    "secondary" =>
      "border-zinc-300 bg-white text-zinc-900 enabled:hover:bg-gray dark:border-form-strokedark dark:bg-form-input dark:text-white dark:enabled:hover:bg-meta-4",
    "ghost" =>
      "border-transparent bg-transparent text-zinc-700 enabled:hover:bg-gray dark:text-bodydark1 dark:enabled:hover:bg-meta-4",
    "bg-danger" => "border-transparent bg-danger text-white enabled:hover:bg-opacity-90"
  }

  def button(assigns) do
    assigns =
      assign(
        assigns,
        :color_classes,
        Map.get(@button_color_classes, assigns.color, assigns.color)
      )

    ~H"""
    <button
      class={[
        "inline-flex h-10 shrink-0 items-center justify-center gap-2 whitespace-nowrap border px-4 py-0 text-center text-sm font-medium transition-colors",
        @rounding,
        @color_classes,
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 dark:focus-visible:ring-offset-boxdark",
        "disabled:cursor-not-allowed disabled:border-stroke disabled:bg-gray disabled:bg-opacity-100 disabled:text-bodydark2 dark:disabled:border-strokedark dark:disabled:bg-meta-4 dark:disabled:text-bodydark2",
        @class
      ]}
      type={@type}
      disabled={@disabled}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Render a dropdown based off a button

  ## Examples

      <.button_dropdown text="Actions">
        <:option>TEST</:option>
      </.button_dropdown>
  """
  attr :text, :string, required: true
  attr :class, :string, default: ""

  slot :option, required: true

  def button_dropdown(assigns) do
    ~H"""
    <div
      x-data="{ dropdownOpen: false }"
      x-on:keydown.escape.stop="dropdownOpen = false; $refs.dropdownTrigger.focus()"
      class={["relative flex", @class]}
    >
      <button
        type="button"
        x-ref="dropdownTrigger"
        x-on:click.prevent="dropdownOpen = !dropdownOpen"
        x-bind:aria-expanded="dropdownOpen ? 'true' : 'false'"
        class="inline-flex h-10 cursor-pointer items-center justify-center gap-2.5 rounded-md bg-primary px-4 py-0 text-sm font-medium text-white hover:bg-opacity-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 dark:focus-visible:ring-offset-boxdark"
      >
        {@text}
        <CoreComponents.icon
          name="hero-chevron-down"
          class="fill-current duration-200 ease-linear mt-1"
          x-bind:class="dropdownOpen && 'rotate-180'"
        />
      </button>

      <div
        x-cloak
        x-show="dropdownOpen"
        x-on:click.outside="dropdownOpen = false"
        class="absolute left-0 top-full z-40 mt-2 w-full rounded-md bg-black py-3 shadow-card"
      >
        <ul class="flex flex-col">
          <li :for={option <- @option}>
            <div class="flex px-5 py-2 font-medium text-bodydark2 hover:text-white cursor-pointer">
              {render_slot(option)}
            </div>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  Render a button with an icon. Optionally include a tooltip.

  Icon-only buttons should pass a `label` for an accessible name; it falls
  back to the tooltip text and is also exposed as a `title` for mouse users.

  ## Examples

      <.icon_button icon_name="hero-check" tooltip="Complete" />
  """
  attr :icon_name, :string, required: true
  attr :class, :string, default: ""
  attr :tooltip, :string, default: nil
  attr :label, :string, default: nil
  attr :rest, :global

  def icon_button(assigns) do
    assigns = assign(assigns, :label, assigns.label || assigns.tooltip)

    ~H"""
    <TextComponents.tooltip position="bottom" tooltip={@tooltip} tooltip_class="text-nowrap">
      <button
        class={[
          "flex items-center justify-center rounded-lg border-2 border-zinc-300 bg-white hover:border-form-strokedark hover:bg-gray dark:border-strokedark dark:bg-form-input dark:hover:border-form-strokedark dark:hover:bg-meta-4",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 dark:focus-visible:ring-offset-boxdark",
          @class
        ]}
        type="button"
        aria-label={@label}
        title={@label}
        {@rest}
      >
        <CoreComponents.icon name={@icon_name} class="text-zinc-700 dark:text-stroke" />
      </button>
    </TextComponents.tooltip>
    """
  end
end
