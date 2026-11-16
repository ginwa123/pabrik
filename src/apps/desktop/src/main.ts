import { createApp } from 'vue'
import { createPinia } from 'pinia'
import piniaPluginPersistedstate from 'pinia-plugin-persistedstate'

import App from './App.vue'
import router from './router'
import './style.css'
import { initTheme } from './theme/runtime'
import { seedIdentityFromCache } from './helpers/userScope'

initTheme()

// Before any store exists: the tab list (and every other user-scoped key) is read at store creation, which happens before the router guard's async `/api/auth/me` …
seedIdentityFromCache()

// Frontend error-log client (POST /api/logs) is DISABLED — it spammed the backend on every console.error/warn.
const app = createApp(App)

const pinia = createPinia()
pinia.use(piniaPluginPersistedstate)

app.use(pinia)
app.use(router)

app.mount('#app')
