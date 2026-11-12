/** The project-row glyph rules: is a stored name drawable, and what a row with
 * no override draws. The name lives on `workspace_items.icon` (Migration 147),
 * on the server, so it is not per-browser state. */
import { ICON_PATHS, type UiIconName } from '../components/ui/icons'

/** Every name the picker offers, sorted so the grid order is stable across
 * builds (object key order is insertion order, which is a refactor away from
 * changing). */
export const PROJECT_ICON_NAMES: readonly UiIconName[] = (
  Object.keys(ICON_PATHS) as UiIconName[]
).sort()

/** True when `value` is a name `UiIcon` can draw. `hasOwnProperty`, not `in`:
 * `'constructor' in ICON_PATHS` is true and would render an empty `<svg>` —
 * the blank row this guard exists to prevent. */
export function isUiIconName(value: unknown): value is UiIconName {
  return typeof value === 'string' && Object.prototype.hasOwnProperty.call(ICON_PATHS, value)
}

/** The glyph a project row draws. An override wins; an unknown one — a name
 * from a newer build, or junk that reached the column another way — degrades
 * to the folder pair instead of rendering nothing. */
export function projectIconFor(
  item: { icon?: string | null } | null | undefined,
  expanded: boolean,
): UiIconName {
  const override = item?.icon
  if (isUiIconName(override)) return override
  return expanded ? 'folder-open' : 'folder'
}
