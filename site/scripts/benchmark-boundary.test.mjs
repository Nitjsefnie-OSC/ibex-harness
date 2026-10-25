import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { findWithheldSuiteLeaks, leakLines, withheldSuites } from './benchmark-boundary.mjs'

const { slug, artifact } = withheldSuites[0]

describe('leakLines', () => {
  it('flags a route, href, or sitemap mention of a withheld slug', () => {
    assert.deepEqual(
      leakLines(slug, artifact, [
        "const nav = [{ href: '/benchmarks/context-assembly' }]",
        "urls: ['/', '/benchmarks', '/benchmarks/context-assembly']",
      ].join('\n')),
      [1, 2],
    )
  })

  it('allows the data-contract artifact filename spelling', () => {
    assert.deepEqual(
      leakLines(slug, artifact, [
        `file: '${artifact}',`,
        `import data from '../../public/benchmarks/${artifact}'`,
        `export const runs = (${artifact}).runs`,
      ].join('\n')),
      [],
    )
  })
})

describe('withheld-suite boundary', () => {
  it('renders no withheld-suite link on any rendered surface', async () => {
    assert.deepEqual(await findWithheldSuiteLeaks(), [])
  })
})
