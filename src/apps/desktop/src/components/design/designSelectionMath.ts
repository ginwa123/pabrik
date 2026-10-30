import type { DesignElement as DesignElementApi } from '../../api'

// Expand a selection to include the transitive children of any group / frame in the selection, so
// dragging a group drags every descendant in one motion — matching Figma's behaviour.
export function expandSelectionWithDescendants(
  ids: ReadonlySet<string>,
  all: ReadonlyArray<DesignElementApi>,
): Set<string> {
  const out = new Set<string>(ids)
  // Iterate to a fixed point so deeply-nested groups (group inside
  // group inside group) all expand.
  let changed = true
  while (changed) {
    changed = false
    for (const e of all) {
      if (out.has(e.id) && e.parent_id && out.has(e.parent_id)) {
        // Already reachable via an expanded ancestor.
        continue
      }
      if (e.parent_id && out.has(e.parent_id) && !out.has(e.id)) {
        out.add(e.id)
        changed = true
      }
    }
  }
  return out
}
