import { readFile, readdir, stat } from 'node:fs/promises'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const site = resolve(here, '..')

/**
 * Suites registered in app/data/benchmarks.ts whose Overview page route does
 * not exist: no rendered surface may link, card, navigate, or sitemap the
 * suite, and its slug may appear in a rendered source only inside the
 * data-contract artifact filename.
 */
export const withheldSuites = [
  { slug: 'context-assembly', artifact: 'context-assembly-benchmark-data.json' },
]

/**
 * Line numbers (1-based) of the rendered-source lines that mention a withheld
 * slug anywhere outside its data-contract artifact filename — i.e. a route,
 * href, card, nav item, or sitemap entry for a page that does not exist.
 */
export function leakLines(slug, artifact, source) {
  const stripped = source.replaceAll(artifact, '')
  return stripped
    .split(/\r?\n/)
    .flatMap((line, index) => line.includes(slug) ? [index + 1] : [])
}

/**
 * Leak lines across every rendered surface: the app sources (.vue/.ts under
 * site/app — landing page, components, nav, data) plus nuxt.config.ts, whose
 * `sitemap.urls` is the sitemap surface. site/e2e is browser-test code, not a
 * rendered surface, and site/content is Docus-authored docs, so neither is scanned.
 */
export async function findWithheldSuiteLeaks() {
  const leaks = []
  const surfaces = [join(site, 'app'), join(site, 'nuxt.config.ts')]

  async function walk(entry) {
    const info = await stat(entry)
    if (!info.isDirectory()) return [entry]
    const entries = await readdir(entry)
    const files = []
    for (const name of entries) files.push(...await walk(join(entry, name)))
    return files
  }

  for (const surface of surfaces) {
    for (const file of await walk(surface)) {
      if (!/\.(?:vue|ts)$/.test(file)) continue
      const source = await readFile(file, 'utf8')
      for (const { slug, artifact } of withheldSuites) {
        for (const line of leakLines(slug, artifact, source)) {
          leaks.push(`${relative(site, file)}:${line}`)
        }
      }
    }
  }
  return leaks
}
