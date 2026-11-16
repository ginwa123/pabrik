/** The sidebar row glyph rules: is a stored name drawable, and what a row with no override draws. */
import { ICON_PATHS, type UiIconName } from '../components/ui/icons'

/** Every name the picker offers, sorted so the grid order is stable across builds (object key order is insertion order, which is a refactor away from changing). */
export const ICON_PICKER_NAMES: readonly UiIconName[] = (
  Object.keys(ICON_PATHS) as UiIconName[]
).sort()

/** True when `value` is a name `UiIcon` can draw. `hasOwnProperty`, not `in` */
export function isUiIconName(value: unknown): value is UiIconName {
  return typeof value === 'string' && Object.prototype.hasOwnProperty.call(ICON_PATHS, value)
}

/** The glyph a folder-shaped row draws — a project, or a document folder. */
export function folderIconFor(
  item: { icon?: string | null } | null | undefined,
  expanded: boolean,
): UiIconName {
  const override = item?.icon
  if (isUiIconName(override)) return override
  return expanded ? 'folder-open' : 'folder'
}

/** The glyph a document row draws. */
export function documentIconFor(item: { icon?: string | null } | null | undefined): UiIconName {
  const override = item?.icon
  return isUiIconName(override) ? override : 'file'
}
