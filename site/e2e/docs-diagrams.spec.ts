import { expect, test } from '@playwright/test'
import { waitHydrated } from './helpers'

// Docs pages ship mermaid code blocks through ProsePre → MermaidDiagram,
// which renders client-side after hydration and lazy-starts each diagram
// when it scrolls near the viewport. The contract: every diagram on the
// page settles — rendered SVG or the visible error state — and none is
// left in the "Rendering diagram" placeholder with no console error.
const pageWithDiagrams = '/docs/proxy/request-routing'

test.describe('docs page mermaid diagrams', () => {
  // The per-figure settled-state expectations below use their own 30s
  // windows; keep the test-level clock above them so a hang surfaces as
  // the assertion's timeout, never the test runner's.
  test.setTimeout(120_000)

  test('every mermaid diagram settles instead of rendering forever', async ({ page }) => {
    await page.goto(pageWithDiagrams)
    await waitHydrated(page)

    const figures = page.locator('figure.mermaid-figure')
    await expect(figures).toHaveCount(2)

    for (const figure of await figures.all()) {
      await figure.scrollIntoViewIfNeeded()
      const canvas = figure.locator('.mermaid-figure__canvas')
      // Settled outcome, scoped to this figure: the rendered SVG or the
      // visible error block — never an indefinite loading placeholder.
      const rendered = canvas.locator('.mermaid-figure__svg svg')
      const failed = canvas.locator('.mermaid-figure__error')
      await expect(rendered.or(failed)).toBeVisible({ timeout: 30_000 })
      await expect(canvas.locator('.mermaid-figure__loading')).toBeHidden({ timeout: 30_000 })
    }
  })

  test('the page\'s valid diagram sources render an svg', async ({ page }) => {
    await page.goto(pageWithDiagrams)
    await waitHydrated(page)

    const figures = page.locator('figure.mermaid-figure')
    await expect(figures).toHaveCount(2)

    for (const figure of await figures.all()) {
      await figure.scrollIntoViewIfNeeded()
      await expect(figure.locator('.mermaid-figure__svg svg')).toBeVisible({ timeout: 30_000 })
    }
  })

  test('surfaces a visible error when the mermaid library never finishes loading', async ({ page }) => {
    // Stall the mermaid library chunk regardless of its hashed name: while
    // its fetch never completes, every diagram on the page would wait on it
    // forever with no console error — exactly the indefinite-spinner
    // failure mode this suite exists to prevent.
    const mermaidChunkSignature = 'registerIconPacks'
    await page.route('**/_nuxt/*.js', async (route) => {
      const response = await route.fetch()
      const body = await response.text()
      if (body.includes(mermaidChunkSignature)) return // hold the route open
      await route.fulfill({ response })
    })

    await page.goto(pageWithDiagrams)
    await waitHydrated(page)

    const figures = page.locator('figure.mermaid-figure')
    await expect(figures).toHaveCount(2)

    for (const figure of await figures.all()) {
      await figure.scrollIntoViewIfNeeded()
      const canvas = figure.locator('.mermaid-figure__canvas')
      const rendered = canvas.locator('.mermaid-figure__svg svg')
      const failed = canvas.locator('.mermaid-figure__error')
      await expect(rendered.or(failed)).toBeVisible({ timeout: 45_000 })
      await expect(canvas.locator('.mermaid-figure__loading')).toBeHidden({ timeout: 45_000 })
    }
  })
})
