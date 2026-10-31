export type RoutinePreset = { label: string; cron: string }

export const ROUTINE_PRESETS: RoutinePreset[] = [
  { label: 'Manual only', cron: '' },
  { label: 'Every hour', cron: '0 * * * *' },
  { label: 'Daily 09:00', cron: '0 9 * * *' },
  { label: 'Weekdays 09:00', cron: '0 9 * * 1-5' },
]

export const ROUTINE_CRON_FIELDS = 'minute hour day-of-month month day-of-week'

export function routinePresetFor(cron: string): RoutinePreset | undefined {
  const trimmed = cron.trim()
  return ROUTINE_PRESETS.find((preset) => preset.cron === trimmed)
}
