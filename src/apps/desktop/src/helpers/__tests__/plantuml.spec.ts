/** Behavioural tests for the PlantUML block URL builder. The encoder is the contract with the
 * server: `~h` + lowercase hex is PlantUML's UNCOMPRESSED link form, and it is what we send because
 * it needs no compressor in the browser. */
import { describe, expect, it } from 'vitest'
import {
  PLANTUML_DEFAULT_SERVER,
  encodePlantuml,
  plantumlSvgUrl,
  resolvePlantumlServer,
} from '../plantuml'

describe('encodePlantuml', () => {
  it('encodes UTF-8 source as `~h` plus lowercase hex', () => {
    expect(encodePlantuml('Ab')).toBe('~h4162')
  })

  it('encodes multi-byte characters byte-wise, not code point-wise', () => {
    // 'é' is 0xC3 0xA9 in UTF-8; an ASCII-only encoder would produce a 1-char escape.
    expect(encodePlantuml('é')).toBe('~h' + 'c3a9')
  })

  it('keeps the newlines and the @startuml wrapper verbatim', () => {
    expect(encodePlantuml('@startuml\nA -> B\n@enduml')).toBe(
      '~h' + Buffer.from('@startuml\nA -> B\n@enduml', 'utf8').toString('hex'),
    )
  })
})

describe('plantumlSvgUrl', () => {
  it('appends /svg/<encoded> to the server', () => {
    expect(plantumlSvgUrl('A -> B', 'https://example.test/plantuml')).toBe(
      'https://example.test/plantuml/svg/~h41202d3e2042',
    )
  })

  it('does not double the slash when the server has a trailing one', () => {
    expect(plantumlSvgUrl('X', 'https://example.test/plantuml/')).toBe(
      plantumlSvgUrl('X', 'https://example.test/plantuml'),
    )
  })
})

describe('resolvePlantumlServer', () => {
  it('defaults to the public renderer so the feature needs no setup', () => {
    expect(PLANTUML_DEFAULT_SERVER).toBe('https://www.plantuml.com/plantuml')
    expect(resolvePlantumlServer()).toBe(PLANTUML_DEFAULT_SERVER)
  })
})
