import { fileURLToPath } from 'node:url'
import { mergeConfig, defineConfig, configDefaults } from 'vitest/config'
import viteConfig from './vite.config'

export default mergeConfig(
  viteConfig,
  defineConfig({
    resolve: {
      // AppLayout transitively imports CodeEditor.vue, which imports
      // `monaco-editor`. Although the package IS installed, evaluating its
      // top-level module body (worker setup via `self.MonacoEnvironment`,
      // `getWorker`, etc.) is unsafe in jsdom — the worker URL paths don't
      // resolve. Vite's import-analysis runs at file-transform time, before
      // vi.mock can intercept, so we alias the bare specifier to a tiny stub
      // for module resolution. The real CodeEditor is stubbed at mount-time
      // so the stub's contents do not matter.
      alias: {
        'monaco-editor': fileURLToPath(
          new URL('./src/__tests__/stubs/monaco-editor.ts', import.meta.url),
        ),
      },
    },
    test: {
      environment: 'jsdom',
      exclude: [...configDefaults.exclude, 'e2e/**'],
      root: fileURLToPath(new URL('./', import.meta.url)),
      setupFiles: ['./src/__tests__/setup.ts'],
      // Bump the default test timeout from vitest's 5000ms to 15000ms.
      // Component-mount tests (AppLayout.*, ChatView.*, DesignView.*,
      // DesignChatDialog, AddDesignElementDialog, …) involve heavy
      // jsdom + Vue Test Utils setup that completes in <500ms on Linux
      // and macOS but consistently pushes past 5000ms on the Windows
      // runner (Node startup + NTFS fs latency). 15s is still well
      // below the per-job timeout and surfaces real hangs (>15s) while
      // letting the slow-but-correct Windows tests pass.
      testTimeout: 15000,
      // Unhandled rejections FAIL the run. `dangerouslyIgnoreUnhandledErrors: true` used to sit
      // here, and it is how a mount that threw before its first assertion reported a green suite:
      // the test "passed" because its assertions never disagreed with an unrendered component. A
      // spec whose async work rejects has a bug, and the suite has to say so.
      dangerouslyIgnoreUnhandledErrors: false,
      onConsoleLog(_log: string, type: 'stdout' | 'stderr') {
        if (type === 'stderr') return false
      },
    },
  }),
)
