/** Idle window between the last settings edit and the PUT that persists it. Long enough that a
 * burst of keystrokes is one save, short enough that tabbing away feels instantaneous. Specs mock
 * this module to 0 so they never have to wait out a real timer. */
export const AUTOSAVE_DELAY_MS = 600
