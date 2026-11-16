/** One home for the kanban tag colour cycle (Migration 067). */
const TAG_HUES = ['violet', 'blue', 'green', 'yellow', 'orange', 'red'] as const

export interface TagStyle {
  backgroundColor: string
  border: string
  color: string
}

const hashTag = (tag: string): number => {
  let hash = 5381
  for (const c of tag.toLowerCase()) hash = ((hash << 5) + hash + c.charCodeAt(0)) >>> 0
  return hash
}

export function tagStyle(tag: string): TagStyle {
  const hue = TAG_HUES[hashTag(tag) % TAG_HUES.length] ?? TAG_HUES[0]
  return {
    backgroundColor: `var(--tag-${hue}-bg)`,
    border: `1px solid var(--tag-${hue}-border)`,
    color: `var(--tag-${hue}-text)`,
  }
}
