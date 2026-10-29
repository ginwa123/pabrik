import {
  asRecord,
  boolField,
  numOrNullField,
  strField,
  strOrNullField,
  unwrapDataRecord,
} from './internal'

export interface KanbanListColumn {
  id: string
  name: string
  position: number
  taskCount: number
}

export interface KanbanListTask {
  id: string
  name: string
  columnId: string | null
  columnName: string | null
  position: number
}

export interface ParsedKanbanList {
  workspaceId: string | null
  itemId: string | null
  boardLabel: string | null
  columns: KanbanListColumn[]
  tasks: KanbanListTask[]
  totalCount: number | null
  limit: number | null
  offset: number | null
  hasMore: boolean
  hint: string | null
  error: string | null
  success: boolean
}

export function parseKanbanList(data: unknown): ParsedKanbanList {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return {
      workspaceId: null,
      itemId: null,
      boardLabel: null,
      columns: [],
      tasks: [],
      totalCount: null,
      limit: null,
      offset: null,
      hasMore: false,
      hint: null,
      error,
      success: false,
    }
  }
  const columns: KanbanListColumn[] = []
  const colsRaw = Array.isArray(o.columns) ? o.columns : []
  for (const item of colsRaw) {
    const r = asRecord(item)
    const id = strField(r, 'id')
    if (!id) continue
    columns.push({
      id,
      name: strField(r, 'name'),
      position: numOrNullField(r, 'position') ?? 0,
      taskCount: numOrNullField(r, 'task_count') ?? 0,
    })
  }
  const tasks: KanbanListTask[] = []
  const tasksRaw = Array.isArray(o.tasks) ? o.tasks : []
  for (const item of tasksRaw) {
    const r = asRecord(item)
    const id = strField(r, 'id')
    if (!id) continue
    tasks.push({
      id,
      name: strField(r, 'name'),
      columnId: strOrNullField(r, 'column_id'),
      columnName: strOrNullField(r, 'column_name'),
      position: numOrNullField(r, 'position') ?? 0,
    })
  }
  const workspaceId = strOrNullField(o, 'workspace_id')
  const itemId = strOrNullField(o, 'item_id')
  return {
    workspaceId,
    itemId,
    boardLabel: strOrNullField(o, 'board') ?? strOrNullField(o, 'name'),
    columns,
    tasks,
    totalCount: numOrNullField(o, 'total_count'),
    limit: numOrNullField(o, 'limit'),
    offset: numOrNullField(o, 'offset'),
    hasMore: boolField(o, 'has_more', false),
    hint: strOrNullField(o, 'hint'),
    error: null,
    success: true,
  }
}

export interface ParsedKanbanMove {
  boardId: string | null
  taskId: string | null
  taskName: string | null
  fromColumnId: string | null
  toColumnId: string | null
  columnId: string | null
  columnName: string | null
  position: number | null
  error: string | null
  success: boolean
}

export function parseKanbanMove(data: unknown): ParsedKanbanMove {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return {
      boardId: null,
      taskId: null,
      taskName: null,
      fromColumnId: null,
      toColumnId: null,
      columnId: null,
      columnName: null,
      position: null,
      error,
      success: false,
    }
  }
  const success = boolField(o, 'success', true)
  return {
    boardId: strOrNullField(o, 'board_id'),
    taskId: strOrNullField(o, 'task_id'),
    taskName: strOrNullField(o, 'task_name'),
    fromColumnId: strOrNullField(o, 'from_column_id'),
    toColumnId: strOrNullField(o, 'to_column_id') ?? strOrNullField(o, 'column_id'),
    columnId: strOrNullField(o, 'column_id'),
    columnName: strOrNullField(o, 'column_name'),
    position: numOrNullField(o, 'position'),
    error: null,
    success,
  }
}

/** Quick parser for the `metadata` object used by ReadCompactedMessages. */
export function parseMetadata(data: unknown): Record<string, string> {
  const result: Record<string, string> = {}
  const o = unwrapDataRecord(data)
  const meta = o.metadata !== undefined ? asRecord(o.metadata) : o
  for (const [key, value] of Object.entries(meta)) {
    if (value === null || value === undefined) continue
    if (typeof value === 'string') result[key] = value
    else if (typeof value === 'number' || typeof value === 'boolean') result[key] = String(value)
  }
  return result
}
