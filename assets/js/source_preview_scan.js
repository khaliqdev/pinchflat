// Source-form "Preview scan" driver (ROADMAP 4.1).
//
// Gathers the form's current values and asks the backend how many videos the
// URL would download, without saving. Vanilla fetch + the csrf-token meta tag
// from the root layout - deliberately NOT a LiveView, per the ROADMAP.
//
// The backend always answers with an estimate (description regex and
// members-only filtering only land at index time), so the result line is
// worded as an estimate no matter what the numbers look like.

const SCAN_ENDPOINT = '/sources/scan'

// The subset of the source form the scan's count math consumes. Values are
// read straight off the form so the preview reflects unsaved edits.
const SCANNED_FIELDS = [
  'original_url',
  'media_profile_id',
  'cookie_behaviour',
  'min_duration_seconds',
  'max_duration_seconds',
  'download_cutoff_date',
  'title_filter_regex',
  'download_media'
]

const csrfToken = () => {
  const meta = document.querySelector("meta[name='csrf-token']")

  return meta ? meta.getAttribute('content') : ''
}

const scanRoot = (button) => button.closest('[data-preview-scan]')

const collectParams = (form) => {
  const params = new URLSearchParams()

  SCANNED_FIELDS.forEach((field) => {
    const input = form.elements[`source[${field}]`]

    if (!input) return

    // Checkboxes post nothing when unchecked, but the scan needs an explicit
    // false to honor "Download Media" being off
    const value = input.type === 'checkbox' ? String(input.checked) : input.value.trim()

    if (value !== '') params.append(`source[${field}]`, value)
  })

  return params
}

const setLoading = (scanSection, loading) => {
  scanSection.querySelector('[data-preview-scan-button]').disabled = loading
  scanSection.querySelector('[data-preview-scan-spinner]').classList.toggle('hidden', !loading)
}

const hideOutputs = (scanSection) => {
  scanSection.querySelector('[data-preview-scan-result]').classList.add('hidden')
  scanSection.querySelector('[data-preview-scan-error]').classList.add('hidden')
}

const addLine = (container, text, bold) => {
  const line = document.createElement('p')
  line.textContent = text
  line.className = bold ? 'font-medium' : 'text-bodydark2 mt-1'

  container.appendChild(line)
}

const showResult = (scanSection, data) => {
  const container = scanSection.querySelector('[data-preview-scan-result]')

  container.textContent = ''
  addLine(
    container,
    `≈ ${Number(data.estimated_downloads).toLocaleString()} of ${Number(data.total_found).toLocaleString()} found will download; final count lands after the first index.`,
    true
  )

  const breakdown = (data.breakdown || [])
    .filter((step) => step.removed > 0)
    .map((step) => `-${Number(step.removed).toLocaleString()} by ${step.label}`)
    .join(', ')

  if (breakdown !== '') addLine(container, breakdown, false)
  if (Number(data.analyzed_entries) < Number(data.total_found)) {
    addLine(
      container,
      `Estimate based on ${Number(data.analyzed_entries).toLocaleString()} of ${Number(data.total_found).toLocaleString()} entries.`,
      false
    )
  }

  container.classList.remove('hidden')
}

const showError = (scanSection, message) => {
  const container = scanSection.querySelector('[data-preview-scan-error]')

  container.textContent = message
  container.classList.remove('hidden')
}

const errorMessageFor = (data) => {
  if (data.errors) {
    return Object.entries(data.errors)
      .map(([field, messages]) => `${field.replace(/_/g, ' ')}: ${messages.join(', ')}`)
      .join(' | ')
  }

  return data.error || 'Scan failed'
}

const runScan = async (button) => {
  const section = scanRoot(button)
  const form = button.closest('form')

  setLoading(section, true)
  hideOutputs(section)

  try {
    // The x-csrf-token header is what protect_from_forgery checks for JS
    // requests - same token the LiveSocket uses (app.js). No Accept header:
    // the :browser pipeline only negotiates html, and the controller answers
    // with JSON regardless
    const response = await fetch(SCAN_ENDPOINT, {
      method: 'POST',
      headers: { 'x-csrf-token': csrfToken() },
      body: collectParams(form)
    })
    const data = await response.json()

    if (response.ok) {
      showResult(section, data.data)
    } else {
      showError(section, errorMessageFor(data))
    }
  } catch (_error) {
    showError(section, 'Scan failed: could not reach the server')
  } finally {
    setLoading(section, false)
  }
}

document.addEventListener('click', (event) => {
  if (!(event.target instanceof Element)) return

  const button = event.target.closest('[data-preview-scan-button]')

  if (button && !button.disabled) runScan(button)
})
