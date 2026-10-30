import type { Rule } from 'eslint'

type Limit = { match: RegExp; max: number; kind: string }

const LIMITS: Limit[] = [
  { match: /\.d\.ts$/, max: 500, kind: 'type declaration' },
  { match: /\.(spec|test)\.ts$/, max: 600, kind: 'test' },
  { match: /\.(vue|ts|mts|tsx)$/, max: 400, kind: 'source' },
]

export const maxFileLines: Rule.RuleModule = {
  meta: {
    type: 'suggestion',
    docs: {
      description:
        'Warn before a Vue/TS file reaches the hard line ceiling enforced by `max-lines`',
    },
    schema: [],
    messages: {
      tooLong:
        'This {{kind}} file is {{actual}} lines. Split it below {{max}} — the hard CI ceiling is close.',
    },
  },
  create(context) {
    const limit = LIMITS.find((entry) => entry.match.test(context.filename))
    if (!limit) return {}
    return {
      Program(node) {
        const actual = context.sourceCode.lines.length
        if (actual <= limit.max) return
        context.report({
          node,
          messageId: 'tooLong',
          data: { kind: limit.kind, actual: String(actual), max: String(limit.max) },
        })
      },
    }
  },
}

export default maxFileLines
