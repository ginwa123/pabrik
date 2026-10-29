/** The methods Sidebar exposes to AppLayout (its `defineExpose` surface). */
export type SidebarHandle = {
  updateChatId: (oldId: string, newId: string) => void
  selectTask: (taskId: string) => void
  deleteTask: (workspaceId: string, itemId: string, taskId: string) => void
  renameTask: (workspaceId: string, itemId: string, taskId: string, currentName: string) => void
  pinTask: (workspaceId: string, itemId: string, taskId: string, isPinned: boolean) => void
}
