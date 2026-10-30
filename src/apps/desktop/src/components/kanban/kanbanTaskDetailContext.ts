/** The provide/inject seam for the KanbanTaskDetail panel: the panel provides one context object
 * (state + actions) and every extracted sub-panel injects it, so a child component holds markup and
 * nothing else. */
import { inject, type InjectionKey } from 'vue'
import type { TaskDetailContext } from './kanbanTaskDetailTypes'

export const TASK_DETAIL_KEY: InjectionKey<TaskDetailContext> = Symbol('kanban-task-detail')

export function useTaskDetailContext(): TaskDetailContext {
  const ctx = inject(TASK_DETAIL_KEY)
  if (!ctx) throw new Error('KanbanTaskDetail context missing — mount through KanbanTaskDetail.vue')
  return ctx
}
