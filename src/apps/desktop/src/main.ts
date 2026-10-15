import { createApp } from 'vue'
import { createPinia } from 'pinia'
import piniaPluginPersistedstate from 'pinia-plugin-persistedstate'

import App from './App.vue'
import router from './router'
import './style.css'

// Frontend error-log client (POST /api/logs) is DISABLED — it spammed
// the backend on every console.error/warn. Keep the helper module +
// its spec for now; just don't install it. App.vue's context re-wiring
// is now a harmless no-op (null-guarded).
// See docs/plans/2026-07-17-frontend-error-logs-design.md.
const app = createApp(App)

const pinia = createPinia()
pinia.use(piniaPluginPersistedstate)

app.use(pinia)
app.use(router)

app.mount('#app')
