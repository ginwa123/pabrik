// Persistence API - API calls for desktop state persistence
// Replaces localStorage calls with server-side persistence

const API_BASE = '/api'

// ============================================
// Type Definitions
// ============================================

export interface Workspace {
  id: string
  name: string
  icon: string
  expanded: boolean
  sort_order?: number
  items?: WorkspaceItem[]
}

export interface WorkspaceItem {
  id: string
  workspace_id?: string
  name: string
  icon: string
  path?: string
  sort_order?: number
  entries?: FolderEntry[]
  isLoaded?: boolean
  isLoading?: boolean
  expanded?: boolean
  tasks?: Task[]
}

export interface Task {
  id: string
  name: string
  description?: string
  completed?: boolean
  createdAt?: Date
}

export interface ChatNavItem {
  id: string
  label: string
  icon: string
  active?: boolean
}

export interface AppState {
  activeWorkspaceItemId: string | null
  activeTaskId: string | null
}

export interface FolderEntry {
  name: string
  path: string
  is_directory: boolean
  is_symlink: boolean
}

// ============================================ Workspace API Functions
// ============================================
/** Fetch all workspaces */
export async function getWorkspaces(): Promise<Workspace[]> {
  const response = await fetch(`${API_BASE}/persistence/workspaces`)
  if (!response.ok) {
    throw new Error(`Failed to get workspaces: HTTP ${response.status}`)
  }
  const data = await response.json()
  return data.workspaces ?? data
}

/**
 * Fetch a single workspace by ID
 */
export async function getWorkspace(id: string): Promise<Workspace> {
  const response = await fetch(`${API_BASE}/persistence/workspaces/${encodeURIComponent(id)}`)
  if (!response.ok) {
    throw new Error(`Failed to get workspace ${id}: HTTP ${response.status}`)
  }
  return response.json()
}

/**
 * Create a new workspace
 */
export async function createWorkspace(name: string, icon: string = '📁'): Promise<Workspace> {
  const response = await fetch(`${API_BASE}/persistence/workspaces`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, icon }),
  })
  if (!response.ok) {
    throw new Error(`Failed to create workspace: HTTP ${response.status}`)
  }
  return response.json()
}

/**
 * Update an existing workspace
 */
export async function updateWorkspace(id: string, data: Partial<Workspace>): Promise<Workspace> {
  const response = await fetch(`${API_BASE}/persistence/workspaces/${encodeURIComponent(id)}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  })
  if (!response.ok) {
    throw new Error(`Failed to update workspace ${id}: HTTP ${response.status}`)
  }
  return response.json()
}

/**
 * Delete a workspace
 */
export async function deleteWorkspace(id: string): Promise<void> {
  const response = await fetch(`${API_BASE}/persistence/workspaces/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
  if (!response.ok) {
    throw new Error(`Failed to delete workspace ${id}: HTTP ${response.status}`)
  }
}

// ============================================ Workspace Item API Functions
// ============================================
/** Create a new workspace item */
export async function createWorkspaceItem(
  workspaceId: string,
  name: string,
  path?: string,
  icon: string = '📄'
): Promise<WorkspaceItem> {
  const response = await fetch(
    `${API_BASE}/persistence/workspaces/${encodeURIComponent(workspaceId)}/items`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, path, icon }),
    }
  )
  if (!response.ok) {
    throw new Error(`Failed to create workspace item: HTTP ${response.status}`)
  }
  return response.json()
}

/**
 * Update a workspace item
 */
export async function updateWorkspaceItem(
  workspaceId: string,
  itemId: string,
  data: Partial<WorkspaceItem>
): Promise<WorkspaceItem> {
  const response = await fetch(
    `${API_BASE}/persistence/workspaces/${encodeURIComponent(workspaceId)}/items/${encodeURIComponent(itemId)}`,
    {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    }
  )
  if (!response.ok) {
    throw new Error(`Failed to update workspace item ${itemId}: HTTP ${response.status}`)
  }
  return response.json()
}

/**
 * Delete a workspace item
 */
export async function deleteWorkspaceItem(workspaceId: string, itemId: string): Promise<void> {
  const response = await fetch(
    `${API_BASE}/persistence/workspaces/${encodeURIComponent(workspaceId)}/items/${encodeURIComponent(itemId)}`,
    { method: 'DELETE' }
  )
  if (!response.ok) {
    throw new Error(`Failed to delete workspace item ${itemId}: HTTP ${response.status}`)
  }
}

// ============================================ Task API Functions
// ============================================
/** Create a new task */
export async function createTask(
  itemId: string,
  name: string,
  description?: string
): Promise<Task> {
  const response = await fetch(`${API_BASE}/persistence/items/${encodeURIComponent(itemId)}/tasks`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, description }),
  })
  if (!response.ok) {
    throw new Error(`Failed to create task: HTTP ${response.status}`)
  }
  return response.json()
}

/**
 * Update a task
 */
export async function updateTask(
  itemId: string,
  taskId: string,
  data: Partial<Task>
): Promise<Task> {
  const response = await fetch(
    `${API_BASE}/persistence/items/${encodeURIComponent(itemId)}/tasks/${encodeURIComponent(taskId)}`,
    {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    }
  )
  if (!response.ok) {
    throw new Error(`Failed to update task ${taskId}: HTTP ${response.status}`)
  }
  return response.json()
}

/**
 * Delete a task
 */
export async function deleteTask(itemId: string, taskId: string): Promise<void> {
  const response = await fetch(
    `${API_BASE}/persistence/items/${encodeURIComponent(itemId)}/tasks/${encodeURIComponent(taskId)}`,
    { method: 'DELETE' }
  )
  if (!response.ok) {
    throw new Error(`Failed to delete task ${taskId}: HTTP ${response.status}`)
  }
}

// ============================================ Chat API Functions
// ============================================
/** Fetch all chats */
export async function getChats(): Promise<ChatNavItem[]> {
  const response = await fetch(`${API_BASE}/persistence/chats`)
  if (!response.ok) {
    throw new Error(`Failed to get chats: HTTP ${response.status}`)
  }
  const data = await response.json()
  return data.chats ?? data
}

/**
 * Create a new chat
 */
export async function createChat(label: string, icon: string = '💬'): Promise<ChatNavItem> {
  const response = await fetch(`${API_BASE}/persistence/chats`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ label, icon }),
  })
  if (!response.ok) {
    throw new Error(`Failed to create chat: HTTP ${response.status}`)
  }
  return response.json()
}

/**
 * Update a chat
 */
export async function updateChat(id: string, data: Partial<ChatNavItem>): Promise<ChatNavItem> {
  const response = await fetch(`${API_BASE}/persistence/chats/${encodeURIComponent(id)}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  })
  if (!response.ok) {
    throw new Error(`Failed to update chat ${id}: HTTP ${response.status}`)
  }
  return response.json()
}

/**
 * Delete a chat
 */
export async function deleteChat(id: string): Promise<void> {
  const response = await fetch(`${API_BASE}/persistence/chats/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
  if (!response.ok) {
    throw new Error(`Failed to delete chat ${id}: HTTP ${response.status}`)
  }
}

// ============================================ App State API Functions
// ============================================
/** Fetch the current app state */
export async function getAppState(): Promise<AppState> {
  const response = await fetch(`${API_BASE}/persistence/app-state`)
  if (!response.ok) {
    throw new Error(`Failed to get app state: HTTP ${response.status}`)
  }
  const data = await response.json()
  return data
}

/**
 * Update the app state
 */
export async function updateAppState(state: Partial<AppState>): Promise<AppState> {
  const response = await fetch(`${API_BASE}/persistence/app-state`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(state),
  })
  if (!response.ok) {
    throw new Error(`Failed to update app state: HTTP ${response.status}`)
  }
  return response.json()
}
