import { defineStore } from 'pinia'
import { ref } from 'vue'

const STORAGE_KEY_CHATS_HEIGHT = 'pabrik-sidebar-chats-height'
const STORAGE_KEY_NAV_EXPANDED = 'pabrik-sidebar-nav-expanded'
// Legacy key kept ONLY to seed the renamed projects key once, so
// existing users don't get a silently re-collapsed section.
const STORAGE_KEY_LEGACY_WORKSPACES_EXPANDED = 'pabrik-sidebar-workspaces-expanded'
const STORAGE_KEY_PROJECTS_EXPANDED = 'pabrik-sidebar-projects-expanded'
// Documents section (Migration 095). Separate key from the projects one
// so collapsing Projects does not collapse Documents — they are
// independent lists and the user collapses them independently.
const STORAGE_KEY_DOCUMENTS_EXPANDED = 'pabrik-sidebar-documents-expanded'
// Pinned section (fix: PINNED gone when RECENT collapsed). Separate key
// from the recents one so collapsing RECENT does not collapse PINNED —
// they are independent lists and the user collapses them independently.
const STORAGE_KEY_PINNED_EXPANDED = 'pabrik-sidebar-pinned-expanded'
const STORAGE_KEY_RIGHT_SIDEBAR_WIDTH = 'pabrik-right-sidebar-width'
// One key, because there is one list: the global/local split was the
// two-tier filesystem, and the list is now one workspace's rows.
const STORAGE_KEY_SKILLS_EXPANDED = 'pabrik-sidebar-skills-expanded'
const DEFAULT_CHATS_HEIGHT = 40
const MIN_CHATS_HEIGHT = 10
const MAX_CHATS_HEIGHT = 80
const DEFAULT_RIGHT_SIDEBAR_WIDTH = 280
const MIN_RIGHT_SIDEBAR_WIDTH = 200
const MAX_RIGHT_SIDEBAR_WIDTH = 600

export const useSidebarStore = defineStore('sidebar', () => {
  // Chats section height (percentage of nav area)
  const loadChatsHeight = (): number => {
    const saved = localStorage.getItem(STORAGE_KEY_CHATS_HEIGHT)
    if (saved) {
      const parsed = parseFloat(saved)
      if (!isNaN(parsed) && parsed >= MIN_CHATS_HEIGHT && parsed <= MAX_CHATS_HEIGHT) {
        return parsed
      }
    }
    return DEFAULT_CHATS_HEIGHT
  }

  const chatsHeight = ref(loadChatsHeight())

  const saveChatsHeight = () => {
    localStorage.setItem(STORAGE_KEY_CHATS_HEIGHT, chatsHeight.value.toString())
  }

  const setChatsHeight = (height: number) => {
    chatsHeight.value = Math.max(MIN_CHATS_HEIGHT, Math.min(MAX_CHATS_HEIGHT, height))
    saveChatsHeight()
  }

  // Load right sidebar width from localStorage
  const loadRightSidebarWidth = (): number => {
    const saved = localStorage.getItem(STORAGE_KEY_RIGHT_SIDEBAR_WIDTH)
    if (saved) {
      const parsed = parseInt(saved, 10)
      if (
        !isNaN(parsed) &&
        parsed >= MIN_RIGHT_SIDEBAR_WIDTH &&
        parsed <= MAX_RIGHT_SIDEBAR_WIDTH
      ) {
        return parsed
      }
    }
    return DEFAULT_RIGHT_SIDEBAR_WIDTH
  }

  const rightSidebarWidth = ref(loadRightSidebarWidth())

  const saveRightSidebarWidth = () => {
    localStorage.setItem(STORAGE_KEY_RIGHT_SIDEBAR_WIDTH, rightSidebarWidth.value.toString())
  }

  const setRightSidebarWidth = (width: number) => {
    rightSidebarWidth.value = Math.max(
      MIN_RIGHT_SIDEBAR_WIDTH,
      Math.min(MAX_RIGHT_SIDEBAR_WIDTH, width),
    )
    saveRightSidebarWidth()
  }

  // Load nav section expanded state from localStorage
  const loadNavExpanded = (): boolean => {
    const saved = localStorage.getItem(STORAGE_KEY_NAV_EXPANDED)
    if (saved !== null) {
      return saved === 'true'
    }
    return true // Default to expanded
  }

  // Load projects section expanded state — the renamed key first,
  // then the legacy workspaces key as a one-time seed source.
  const loadProjectsExpanded = (): boolean => {
    const saved = localStorage.getItem(STORAGE_KEY_PROJECTS_EXPANDED)
    if (saved !== null) {
      return saved === 'true'
    }
    const legacy = localStorage.getItem(STORAGE_KEY_LEGACY_WORKSPACES_EXPANDED)
    if (legacy !== null) {
      return legacy === 'true'
    }
    return true // Default to expanded
  }

  const navExpanded = ref(loadNavExpanded())
  const projectsExpanded = ref(loadProjectsExpanded())

  // Load documents section expanded state. Default expanded so a fresh
  // install shows the new section's contents, matching the projects and
  // recent sections.
  const loadDocumentsExpanded = (): boolean => {
    const saved = localStorage.getItem(STORAGE_KEY_DOCUMENTS_EXPANDED)
    if (saved !== null) {
      return saved === 'true'
    }
    return true
  }

  const documentsExpanded = ref(loadDocumentsExpanded())

  const saveDocumentsExpanded = () => {
    localStorage.setItem(STORAGE_KEY_DOCUMENTS_EXPANDED, String(documentsExpanded.value))
  }

  const toggleDocumentsExpanded = () => {
    documentsExpanded.value = !documentsExpanded.value
    saveDocumentsExpanded()
  }

  // Pinned section expanded state. Default expanded so existing pins stay
  // visible, matching the recents section. Independent from navExpanded
  // so collapsing RECENT keeps PINNED on screen.
  const loadPinnedExpanded = (): boolean => {
    const saved = localStorage.getItem(STORAGE_KEY_PINNED_EXPANDED)
    if (saved !== null) {
      return saved === 'true'
    }
    return true
  }

  const pinnedExpanded = ref(loadPinnedExpanded())

  const savePinnedExpanded = () => {
    localStorage.setItem(STORAGE_KEY_PINNED_EXPANDED, String(pinnedExpanded.value))
  }

  const togglePinnedExpanded = () => {
    pinnedExpanded.value = !pinnedExpanded.value
    savePinnedExpanded()
  }

  const saveNavExpanded = () => {
    localStorage.setItem(STORAGE_KEY_NAV_EXPANDED, String(navExpanded.value))
  }

  const saveProjectsExpanded = () => {
    localStorage.setItem(STORAGE_KEY_PROJECTS_EXPANDED, String(projectsExpanded.value))
  }

  const toggleNavExpanded = () => {
    navExpanded.value = !navExpanded.value
    saveNavExpanded()
  }

  const toggleProjectsExpanded = () => {
    projectsExpanded.value = !projectsExpanded.value
    saveProjectsExpanded()
  }

  // Load skills section expanded state from localStorage
  const loadSkillsExpanded = (): boolean => {
    const saved = localStorage.getItem(STORAGE_KEY_SKILLS_EXPANDED)
    if (saved !== null) {
      return saved === 'true'
    }
    return true // Default to expanded
  }

  const skillsExpanded = ref(loadSkillsExpanded())

  const saveSkillsExpanded = () => {
    localStorage.setItem(STORAGE_KEY_SKILLS_EXPANDED, String(skillsExpanded.value))
  }

  const toggleSkillsExpanded = () => {
    skillsExpanded.value = !skillsExpanded.value
    saveSkillsExpanded()
  }

  return {
    chatsHeight,
    setChatsHeight,
    navExpanded,
    projectsExpanded,
    toggleNavExpanded,
    toggleProjectsExpanded,
    documentsExpanded,
    toggleDocumentsExpanded,
    pinnedExpanded,
    togglePinnedExpanded,
    rightSidebarWidth,
    setRightSidebarWidth,
    skillsExpanded,
    toggleSkillsExpanded,
  }
})
