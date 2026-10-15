<!--
  DesignElementPreview — sandboxed <iframe> that renders the element's
  stored HTML body.

  Used as the live preview inside the PropertiesPanel and on the canvas
  itself (when the user double-clicks an element for inline edit). The
  iframe is sandboxed to allow scripts only (no same-origin, no top-
  navigation) so the user-pasted HTML can't reach the host document.

  Public API:
    props:
      html           string   the element's stored HTML body
      editable       boolean  when true, the iframe body becomes
                              contentEditable; on blur, the new innerHTML
                              is emitted as htmlChanged. Default false.
      pointerEvents  'auto' | 'none'   when 'none', clicks fall through
                              to the parent DesignElement (drag/resize/
                              select). The canvas passes 'none'; the
                              PropertiesPanel Monaco preview passes 'auto'.
      fill           string   the element's CSS fill color (e.g.
                              "rgba(15, 14, 13, 0.78)" or "#ffffff").
                              Applied to the iframe's inline
                              `background` style so the element's color
                              renders correctly when its srcdoc HTML is
                              empty or transparent. When empty / unset
                              the iframe background is 'transparent' and
                              the parent wrapper's fill shows through.
                              Default ''.
    emits:
      htmlChanged [html: string]

  Test contract: data-testid="design-element-preview" on the iframe.

  Notes:
    - We deliberately do NOT use postMessage for the read-back; the
      blur event on the iframe fires inside the parent window and the
      inner body's innerHTML is readable via the iframe contentDocument
      when sandbox is "allow-same-origin" — but we use
      "allow-scripts" only, so we listen to a custom "previewChanged"
      event the inner script can fire (or, for the readonly case,
      simply no read-back).
    - When `editable=true`, the parent's contenteditable on the body
      element makes the iframe content editable; the parent listens
      for blur and reads `iframe.contentDocument.body.innerHTML`.
    - The `srcdoc` is wrapped with a `<style>html,body{margin:0;
      height:100%}</style>` preamble (see `iframeHtml` below) so
      percentage-based layouts inside the user's HTML resolve
      correctly — the iframe body defaults to `height: auto`, which
      would otherwise collapse every `height: 100%` container to 0.
    - The `html` prop is bound through the `iframeHtml` computed so
      Vue's reactivity keeps the srcdoc in sync with `props.html`.
-->
<script setup lang="ts">
import { computed, onUpdated, ref } from 'vue'

const props = withDefaults(
  defineProps<{
    html: string
    editable?: boolean
    // Pointer-events mode for the iframe. The canvas passes 'none' so clicks fall through to the
    // parent element (drag / resize / select); the editable Monaco preview would pass 'auto' so the
    // user can interact with the iframe content.
    pointerEvents?: 'auto' | 'none'
    // The element's CSS fill color. Applied to the iframe's inline background so the element
    // renders with its true color when the srcdoc HTML is empty / transparent. Empty string =
    // transparent (the wrapper's fill shows through). Default ''.
    // Pre-fix history: the iframe had a hardcoded `background: white` which leaked through any
    // element with `fill: ''` / transparent fill, producing visible white rectangles wherever small
    // elements (input fields, buttons, labels) sat on the canvas.
    // For the "Task Dialog" design this was particularly visible — the backdrop (which should be a
    // dark semi-transparent overlay) rendered as a huge white slab because its empty HTML body
    // relied on the wrapper's fill.
    // See project memory "design-element-rectangle-covers-iframe" for the parallel white-rectangle
    // bug; this fix completes the white-bleed story.
    fill?: string
  }>(),
  {
    editable: false,
    pointerEvents: 'auto',
    fill: '',
  },
)

const emit = defineEmits<{
  htmlChanged: [html: string]
}>()

// Iframe srcdoc body has no implicit height. Without an explicit
// `height: 100%` on <html>/<body>, any `height: 100%` on the
// user's outer <div> collapses to 0 (because body is `height: auto`),
// and any `position: relative` on that div becomes a 0-height
// containing block for absolutely-positioned children — those
// children collapse too, and the iframe's background (set inline
// below via `props.fill` or 'transparent' fallback) shows through.
//
// Prepending a stylesheet that forces html/body to fill the iframe
// makes percentage-based layouts (and position:relative containing
// blocks) behave as users expect.
const iframeHtml = computed(() => `<style>html,body{margin:0;height:100%;}</style>${props.html}`)

const iframeRef = ref<HTMLIFrameElement | null>(null)

// Wire up contenteditable + blur handler on the iframe's body once the iframe has loaded its
// srcdoc. We can't do this in `onMounted` because the srcdoc is async — by the time
// `iframeRef.value` is attached, the inner document may not exist yet.
// A `load` listener on the iframe fires after srcdoc parse completes.
const onIframeLoad = (): void => {
  if (!props.editable) return
  const iframe = iframeRef.value
  if (!iframe) return
  const doc = iframe.contentDocument
  if (!doc) return
  const body = doc.body
  if (!body) return
  body.contentEditable = 'true'
  body.style.outline = 'none'
  body.addEventListener('blur', () => {
    emit('htmlChanged', body.innerHTML)
  })
}

// Re-attach the listener when `editable` flips from false to true (the user just opened the edit
// panel).
// The load event fires only once per srcdoc change, so a prev-value guard on update covers the
// readonly→editable transition; onIframeLoad itself already guards on `props.editable` for the
// mount path.
const prevEditable = ref(props.editable)
onUpdated(() => {
  if (props.editable && !prevEditable.value) onIframeLoad()
  prevEditable.value = props.editable
})
</script>

<template>
  <iframe
    ref="iframeRef"
    sandbox="allow-scripts"
    class="w-full h-full"
    :style="{
      border: 'none',
      background: props.fill || 'transparent',
      pointerEvents: props.pointerEvents,
    }"
    :srcdoc="iframeHtml"
    data-testid="design-element-preview"
    @load="onIframeLoad"
  />
</template>
