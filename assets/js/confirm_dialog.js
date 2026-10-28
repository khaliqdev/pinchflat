// App-wide confirm dialog driver, replacing the browser's native confirm().
//
// The dialog markup is rendered once from the root layout (CoreComponents
// confirm_dialog/1). Any element carrying `data-confirm-dialog` opens it on
// click instead of performing its own action; confirming replays the
// trigger's action, cancelling does nothing.
//
// Per-trigger options (all optional):
//   data-confirm-title / data-confirm-message  - dialog copy; `{count}` in the
//     message is replaced with the number of checked selected_ids[] boxes in
//     the trigger's form
//   data-confirm-confirm-text / data-confirm-cancel-text - button labels
//   data-confirm-kind="danger" - renders the confirm button in red
//   data-destructive - opens the dialog with focus on Cancel so a stray Enter
//     can't immediately run the action; danger-kind triggers are treated as
//     destructive too
//
// We intercept in the capture phase and preventDefault, so phoenix_html's own
// data-confirm/data-method window handler (which bails on defaultPrevented)
// and LiveView/Alpine click handlers never fire for the intercepted click.

const DEFAULT_TITLE = 'Please confirm'
const DEFAULT_MESSAGE = 'Are you sure you want to continue?'
const DEFAULT_CONFIRM_TEXT = 'Confirm'
const DEFAULT_CANCEL_TEXT = 'Cancel'

const FOCUSABLE_SELECTOR =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

// Single source for the confirm button's classes so `data-confirm-kind` can
// swap colors without rendering two buttons.
const CONFIRM_BUTTON_BASE = 'rounded-md px-3 py-1.5 text-sm font-medium text-white hover:bg-opacity-90'
const CONFIRM_BUTTON_CLASSES = {
  default: `${CONFIRM_BUTTON_BASE} bg-primary`,
  danger: `${CONFIRM_BUTTON_BASE} bg-meta-1`
}

let pendingTrigger = null
let lastFocused = null

const dialogRoot = () => document.querySelector('[data-confirm-dialog-root]')

const attr = (el, name, fallback) => el.getAttribute(name) || fallback

const selectedCount = (trigger) => {
  const form = trigger.closest('form')

  return form ? form.querySelectorAll('input[type="checkbox"][name="selected_ids[]"]:checked').length : 0
}

const isDestructive = (trigger) =>
  trigger.hasAttribute('data-destructive') || trigger.getAttribute('data-confirm-kind') === 'danger'

const fillDialog = (trigger) => {
  const dialog = dialogRoot()
  const count = selectedCount(trigger)
  const message = attr(trigger, 'data-confirm-message', DEFAULT_MESSAGE).replace('{count}', count)
  const confirmButton = dialog.querySelector('[data-confirm-confirm]')

  dialog.querySelector('[data-confirm-title]').textContent = attr(trigger, 'data-confirm-title', DEFAULT_TITLE)
  dialog.querySelector('[data-confirm-description]').textContent = message
  confirmButton.textContent = attr(trigger, 'data-confirm-confirm-text', DEFAULT_CONFIRM_TEXT)
  confirmButton.className =
    trigger.getAttribute('data-confirm-kind') === 'danger'
      ? CONFIRM_BUTTON_CLASSES.danger
      : CONFIRM_BUTTON_CLASSES.default
  dialog.querySelector('[data-confirm-cancel]').textContent = attr(trigger, 'data-confirm-cancel-text', DEFAULT_CANCEL_TEXT)
}

const openDialog = (trigger) => {
  pendingTrigger = trigger
  lastFocused = document.activeElement

  fillDialog(trigger)

  dialogRoot().classList.remove('hidden')
  document.body.classList.add('overflow-hidden')
  const initialFocus = isDestructive(trigger) ? '[data-confirm-cancel]' : '[data-confirm-confirm]'
  dialogRoot().querySelector(initialFocus).focus()
}

const closeDialog = () => {
  dialogRoot().classList.add('hidden')
  document.body.classList.remove('overflow-hidden')

  if (lastFocused && lastFocused.isConnected) lastFocused.focus()
  lastFocused = null
  pendingTrigger = null
}

const buildHiddenInput = (name, value) => {
  const input = document.createElement('input')
  input.type = 'hidden'
  input.name = name
  input.value = value

  return input
}

// Replays the intercepted action. data-method links submit a POST form built
// exactly like phoenix_html's handleClick (deps/phoenix_html/priv/static/
// phoenix_html.js) so _csrf_token/_method semantics are identical.
const performConfirmedAction = () => {
  const trigger = pendingTrigger

  closeDialog()
  if (!trigger) return

  const method = trigger.getAttribute('data-method')
  const to = trigger.getAttribute('data-to')

  if (method && to) {
    const form = document.createElement('form')

    form.method = 'post'
    form.action = to
    form.style.display = 'none'
    form.appendChild(buildHiddenInput('_csrf_token', trigger.getAttribute('data-csrf')))
    form.appendChild(buildHiddenInput('_method', method))
    document.body.appendChild(form)
    form.submit()
  } else if (trigger.form) {
    const form = trigger.form

    if (form.requestSubmit) {
      // Mark the form so its submit guard (below) lets this dialog-confirmed
      // submission through while implicit submissions stay blocked
      form.dataset.reConfirmBypass = 'true'
      form.requestSubmit(trigger)
    } else {
      // form.submit() fires no submit event, so no bypass flag is needed
      form.submit()
    }
  } else if (trigger.getAttribute('href')) {
    window.location.assign(trigger.getAttribute('href'))
  }
}

document.addEventListener(
  'click',
  (event) => {
    if (event.defaultPrevented || !(event.target instanceof Element)) return

    const trigger = event.target.closest('[data-confirm-dialog]')

    if (trigger) {
      event.preventDefault()
      event.stopPropagation()
      openDialog(trigger)

      return
    }

    const dialog = dialogRoot()

    if (!dialog || dialog.classList.contains('hidden')) return

    if (event.target.closest('[data-confirm-confirm]')) {
      performConfirmedAction()
    } else if (
      event.target.closest('[data-confirm-cancel]') ||
      event.target.closest(`#${dialog.id}-bg`) ||
      !dialog.contains(event.target)
    ) {
      closeDialog()
    }
  },
  true
)

// Forms marked data-confirm-form may only submit through the dialog: this
// guard blocks implicit submissions (e.g. pressing Enter while a checkbox is
// focused), which would otherwise bypass the confirm step entirely.
document.addEventListener('submit', (event) => {
  const form = event.target

  if (!(form instanceof HTMLFormElement) || !form.hasAttribute('data-confirm-form')) return

  if (form.dataset.reConfirmBypass === 'true') {
    delete form.dataset.reConfirmBypass
  } else {
    event.preventDefault()
  }
})

document.addEventListener('keydown', (event) => {
  const dialog = dialogRoot()

  if (!dialog || dialog.classList.contains('hidden')) return

  if (event.key === 'Escape') {
    closeDialog()
  } else if (event.key === 'Tab') {
    // Minimal focus trap so Tab/Shift+Tab cycle inside the dialog while it
    // declares aria-modal="true" and holds focus
    const focusables = Array.from(dialog.querySelectorAll(FOCUSABLE_SELECTOR))
    const first = focusables[0]
    const last = focusables[focusables.length - 1]
    const active = document.activeElement
    const escaped = active && !dialog.contains(active)

    if (focusables.length === 0) {
      event.preventDefault()
    } else if (event.shiftKey && (active === first || escaped)) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && (active === last || escaped)) {
      event.preventDefault()
      first.focus()
    }
  }
})
