# PR #1114 proof screenshots

Hosting only: the pull request links these images from the body so the diff
stays clean. Delete this branch once the PR is merged or closed.

Captured by driving the branch code in headless Chromium (`agent-browser`) at
1440×900, served by `npx vite` with `/api` proxied to an isolated backend on
port 8084 (fresh `HOME`, its own `agent.db`).

- `01-add-routine-in-menu.png` — the projects "+" menu, **Add Routine** enabled
- `02-add-routine-dialog.png` — the create dialog: instruction, cron with the
  `Weekdays 09:00` preset applied, folder chosen, Add enabled
- `03-routine-view-routine-tab.png` — the routine right after creating it:
  status `Idle`, `next 2026-11-02 09:00:00 UTC`
- `04-routine-view-agent-tab.png` — the Agent tab: tools, system prompts,
  knowledge, local memories
- `05-run-now-running.png` — after `▶ Run now`: status `Running`
- `06-before-fix-footer-clipped.png` — 1280×577: the pre-`d6e30e610` dialog cuts
  its own footer off (`add_button 547..582` vs `dialog ..534`, the click lands on
  the backdrop: `clickable: false`)
- `07-after-fix-footer-visible.png` — same viewport after the fix: the footer is
  inside the box (`add_button 482..517`, `clickable: true`)
