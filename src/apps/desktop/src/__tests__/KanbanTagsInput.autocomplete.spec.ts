/**
 * KanbanTagsInput — autocomplete dropdown behavioural tests.
 *
 * Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md
 * (Task 2.5 — RED step, Task 2.6 — GREEN step)
 *
 * Covers:
 *   1. Dropdown visibility (empty / non-empty suggestions)
 *   2. Filtering by case-insensitive prefix
 *   3. Hiding suggestions already on the task
 *   4. Click-to-commit
 *   5. Keyboard navigation (ArrowDown + Enter)
 *   6. Escape handling (close without commit)
 *   7. Blur with delayed close
 *   8. Enter without highlight still commits the typed draft
 *   9. Scroll sentinel rendering (gated on hasMore)
 *   10. "Loading more…" indicator (gated on loadingMore)
 *   11. IntersectionObserver fires onLoadMore when sentinel visible
 *   12. rootMargin config check
 */
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import KanbanTagsInput from '../components/kanban/KanbanTagsInput.vue'

// jsdom does NOT implement IntersectionObserver natively. The component's watcher fires on focus
// and unconditionally calls `new IntersectionObserver(...)` when the scroll sentinel is in the DOM.

// Without a mock, that call throws a ReferenceError and cascades into a corrupted test runner for
// subsequent tests (the next `mount` returns a wrapper with a null root, surfacing as `Cannot read
// properties of null (reading '$')`).

// Install a no-op IntersectionObserver for every test by default; the "IntersectionObserver fires
// onLoadMore" test overrides the global with a capturing mock and restores the no-op in `finally`.
class NoopIntersectionObserver {
  constructor(_cb: IntersectionObserverCallback, _opts?: IntersectionObserverInit) {}
  observe(_target: Element): void {}
  disconnect(): void {}
  unobserve(_target: Element): void {}
  takeRecords(): IntersectionObserverEntry[] {
    return []
  }
  root: Element | null = null
  rootMargin = '0px'
  thresholds = [0]
}

describe('KanbanTagsInput — autocomplete dropdown', () => {
  beforeEach(() => {
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(globalThis as any).IntersectionObserver = NoopIntersectionObserver
  })

  it('does not show the dropdown when there are no suggestions', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: [] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(false)
  })

  it('shows the dropdown when focused and suggestions are provided', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug', 'urgent', 'frontend'] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').exists()).toBe(true)
  })

  it('filters suggestions by case-insensitive prefix', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug', 'urgent', 'bugfix', 'frontend'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'BUG'
    await input.trigger('input')
    await input.trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bugfix"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').exists()).toBe(false)
  })

  it('hides suggestions that are already chips on the task', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: ['bug'], suggestions: ['bug', 'urgent', 'frontend'] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').exists()).toBe(true)
  })

  it('clicking a suggestion commits it as a tag and KEEPS the dropdown open (user can pick more without re-focusing)', async () => {
    // Plan: 2026-08-06-dropdown-tags-feedback. User feedback #2: "after enter select dropdown, the
    // dropdown not show up agai, it should show up". The pre-fix behaviour closed the dropdown
    // after every commit, forcing the user to click back into the input to pick the next tag.

    // Keep the dropdown open so the user can pick N tags in one focused session.
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug', 'urgent', 'frontend'] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    await wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').trigger('mousedown')
    // Simulate v-model round-trip: parent updates modelValue in response
    // to the emit. Without this, props.modelValue stays [] and the
    // next assertion (the picked tag is filtered out) would fail.
    await wrapper.setProps({ modelValue: ['bug'] })
    await nextTick()
    // The chip was added.
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['bug']])
    // The dropdown stays open.
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(true)
    // The picked tag is no longer in the list (filtered out by the
    // "already on the task" check in filteredSuggestions).
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').exists()).toBe(false)
    // The other suggestions are still pickable.
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-frontend"]').exists()).toBe(true)
  })

  it('user can pick multiple tags in one focused session (regression for dropdown-closes-after-pick)', async () => {
    // Plan: 2026-08-06-dropdown-tags-feedback. The user-reported flow: open dialog → focus tags
    // input → click suggestion → click another suggestion → click another → ...  without the
    // dropdown closing in between.

    // After-pick filtering keeps the dropdown showing only the still-pickable tags.
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: ['bug'], suggestions: ['bug', 'urgent', 'frontend', 'flaky'] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    // Dropdown is open with the unpicked suggestions.
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-frontend"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-flaky"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').exists()).toBe(false)
    // Pick another tag.
    await wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').trigger('mousedown')
    await wrapper.setProps({ modelValue: ['bug', 'urgent'] })
    await nextTick()
    // Dropdown still open, picked tag removed from the list.
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-frontend"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-flaky"]').exists()).toBe(true)
    // The emitted values include the new tag appended to the existing chip.
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['bug', 'urgent']])
  })

  it('ArrowDown + Enter commits the highlighted suggestion', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug', 'urgent'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    await input.trigger('focus')
    await nextTick()
    await input.trigger('keydown', { key: 'ArrowDown' })
    await input.trigger('keydown', { key: 'Enter' })
    await nextTick()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['bug']])
  })

  it('Escape closes the dropdown but does NOT commit a draft', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'partial'
    await input.trigger('input')
    await input.trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(true)
    await input.trigger('keydown', { key: 'Escape' })
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(false)
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
  })

  it('hides the dropdown after blur (delayed close so clicks can fire)', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug'] },
    })
    const input = wrapper.find('[data-testid="kanban-tags-input-field"]')
    await input.trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(true)
    await input.trigger('blur')
    await new Promise((r) => setTimeout(r, 200))
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(false)
  })

  it('Enter without a highlight still commits the typed draft (existing behavior)', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'custom-tag'
    await input.trigger('input')
    await input.trigger('focus')
    await input.trigger('keydown', { key: 'Enter' })
    await nextTick()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['custom-tag']])
  })

  // ─── Pagination tests ──────────────────────────────────────────────────

  it('renders the scroll sentinel when hasMore is true', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: {
        modelValue: [],
        suggestions: ['bug'],
        hasMore: true,
        loadingMore: false,
      },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions-sentinel"]').exists()).toBe(true)
  })

  it('does NOT render the scroll sentinel when hasMore is false', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: {
        modelValue: [],
        suggestions: ['bug'],
        hasMore: false,
        loadingMore: false,
      },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions-sentinel"]').exists()).toBe(false)
  })

  it('renders the "Loading more…" indicator when loadingMore is true', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: {
        modelValue: [],
        suggestions: ['bug'],
        hasMore: true,
        loadingMore: true,
      },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions-loading"]').exists()).toBe(true)
  })

  it('IntersectionObserver fires onLoadMore when the scroll sentinel is visible', async () => {
    // jsdom doesn't trigger IntersectionObserver by default, so we stub the constructor to call the
    // callback with isIntersecting=true synchronously.

    // Note: the vitest tsconfig has `"lib": []` (no DOM types), so we use `any` for the captured
    // cb/opts instead of the global IntersectionObserver types (which are undeclared).
     
    const originalIO = globalThis.IntersectionObserver
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let capturedCb: any = null
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let capturedOpts: any = null
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(globalThis as any).IntersectionObserver = class MockIntersectionObserver {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      constructor(cb: any, opts?: any) {
        capturedCb = cb
        capturedOpts = opts ?? null
      }
      observe() {}
      disconnect() {}
    }

    const onLoadMore = vi.fn()
    try {
      const wrapper = mount(KanbanTagsInput, {
        props: {
          modelValue: [],
          suggestions: ['bug', 'urgent'],
          hasMore: true,
          loadingMore: false,
          onLoadMore,
        },
      })
      await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
      await nextTick()
      // Fire the observer callback as if the sentinel is visible.
      capturedCb?.(
        [{ isIntersecting: true }],
        null,
       
      )
      expect(onLoadMore).toHaveBeenCalledTimes(1)
      // Verify the rootMargin config (100px preload).
      expect(capturedOpts?.rootMargin).toBe('0px 0px 100px 0px')
    } finally {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(globalThis as any).IntersectionObserver = originalIO
    }
  })
})
