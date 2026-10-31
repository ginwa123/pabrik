<script setup lang="ts">
import { ref, computed, nextTick, onBeforeUnmount, onMounted, onUpdated } from 'vue'
import { getSystemFolder, listFolder, type FolderEntry } from '../../api'
import FilePickerDialog from '../FilePickerDialog.vue'
import UiIcon from '../ui/UiIcon.vue'

export type RoutineCreateOptions = {
  instruction: string
  schedule: string
}

const props = defineProps<{ show: boolean }>()

const emit = defineEmits<{
  close: []
  create: [name: string, path: string, options: RoutineCreateOptions]
}>()

const PRESETS: { label: string; cron: string }[] = [
  { label: 'Manual only', cron: '' },
  { label: 'Every hour', cron: '0 * * * *' },
  { label: 'Daily 09:00', cron: '0 9 * * *' },
  { label: 'Weekdays 09:00', cron: '0 9 * * 1-5' },
]

const name = ref('')
const selectedPath = ref('')
const instruction = ref('')
const schedule = ref('')
const showPicker = ref(false)
const nameInput = ref<HTMLInputElement | null>(null)
const nameTouched = ref(false)
const pathTouched = ref(false)
const scheduleTouched = ref(false)

const nameError = computed<string | null>(() => {
  if (!nameTouched.value) return null
  if (name.value.trim().length === 0) return 'Name is required'
  return null
})

const pathError = computed<string | null>(() => {
  if (!pathTouched.value) return null
  if (selectedPath.value.length === 0) return 'Folder is required (routines need a cwd)'
  return null
})

const scheduleError = computed<string | null>(() => {
  if (!scheduleTouched.value) return null
  const trimmed = schedule.value.trim()
  if (trimmed === '') return null
  if (trimmed.split(/\s+/).length !== 5)
    return 'A cron schedule has 5 fields: minute hour day-of-month month day-of-week'
  return null
})

const activePreset = computed<string | null>(() => {
  const trimmed = schedule.value.trim()
  const hit = PRESETS.find((p) => p.cron === trimmed)
  return hit ? hit.label : null
})

const loadItemsForPicker = async (path: string): Promise<FolderEntry[]> => {
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
}

const handleFolderSelected = (path: string) => {
  selectedPath.value = path
  pathTouched.value = true
  showPicker.value = false
}

const applyPreset = (cron: string) => {
  schedule.value = cron
  scheduleTouched.value = true
}

const canSubmit = computed(
  () => name.value.trim().length > 0 && selectedPath.value.length > 0 && scheduleError.value === null,
)

const handleCreate = () => {
  const trimmedName = name.value.trim()
  if (!canSubmit.value) return
  emit('create', trimmedName, selectedPath.value, {
    instruction: instruction.value.trim(),
    schedule: schedule.value.trim(),
  })
  handleClose()
}

const handleClose = () => emit('close')

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') handleClose()
}

const handleOpen = async () => {
  name.value = ''
  selectedPath.value = ''
  instruction.value = ''
  schedule.value = ''
  showPicker.value = false
  nameTouched.value = false
  pathTouched.value = false
  scheduleTouched.value = false
  await nextTick()
  nameInput.value?.focus()
}

onBeforeUnmount(() => {
  document.body.style.overflow = ''
})

const wasShown = ref(props.show)
onMounted(() => {
  if (props.show) void handleOpen()
})
onUpdated(() => {
  if (props.show && !wasShown.value) void handleOpen()
  wasShown.value = props.show
})
</script>

<template>
  <Teleport to="body">
    <Transition name="add-routine-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-routine-title"
        data-testid="add-routine-dialog"
      >
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6)"
          @click="handleClose"
        />
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            max-height: 85vh;
          "
        >
          <div class="px-5 pt-5 pb-3">
            <h3
              id="add-routine-title"
              class="text-lead font-semibold flex items-center gap-2"
              style="color: var(--semantic-text)"
            >
              <UiIcon name="stopwatch" />
              Add Routine
            </h3>
            <p class="text-dense mt-1" style="color: var(--semantic-text-dim)">
              A routine is an agent that fires on a schedule. Give it an instruction now — you can
              refine the cron, tools and knowledge afterwards.
            </p>
          </div>

          <div class="px-5 pb-3">
            <label class="block text-dense font-medium mb-2" style="color: var(--semantic-text-dim)"
              >Routine name</label
            >
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="Nightly check"
              data-testid="add-routine-name"
              :aria-invalid="nameError !== null"
              class="w-full px-3 py-2 rounded-lg text-body outline-none"
              :style="{
                backgroundColor: 'var(--semantic-sidebar-bg)',
                border: `1px solid ${nameError ? 'var(--color-red)' : 'var(--color-border)'}`,
                color: 'var(--semantic-text)',
              }"
              @input="nameTouched = true"
              @blur="nameTouched = true"
              @keyup.enter="handleCreate"
            />
            <p v-if="nameError" class="text-dense mt-1" style="color: var(--color-red)">
              {{ nameError }}
            </p>
          </div>

          <div class="px-5 pb-3">
            <label class="block text-dense font-medium mb-2" style="color: var(--semantic-text-dim)"
              >Folder (cwd)</label
            >
            <button
              type="button"
              @click="
                showPicker = true;
                pathTouched = true
              "
              data-testid="add-routine-choose-folder"
              class="w-full px-3 py-2 rounded-lg text-body flex items-center justify-between gap-2"
              :style="{
                backgroundColor: selectedPath
                  ? 'var(--semantic-active-bg)'
                  : 'var(--semantic-sidebar-bg)',
                border: `1px solid ${pathError ? 'var(--color-red)' : 'var(--color-border)'}`,
                color: selectedPath ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
              }"
            >
              <span class="truncate flex-1 text-left font-mono" :title="selectedPath">
                {{ selectedPath || 'Choose folder...' }}
              </span>
              <span
                v-if="selectedPath"
                class="text-dense shrink-0"
                style="color: var(--semantic-text-dim)"
                >Browse</span
              >
              <UiIcon
                v-else
                name="folder-open"
                class="w-4 h-4 shrink-0"
                style="color: var(--semantic-text-dim)"
              />
            </button>
            <p v-if="pathError" class="text-dense mt-1" style="color: var(--color-red)">
              {{ pathError }}
            </p>
          </div>

          <div class="px-5 pb-3">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim)"
              for="add-routine-instruction"
              >Instruction (fired on every run)</label
            >
            <textarea
              id="add-routine-instruction"
              v-model="instruction"
              rows="3"
              placeholder="Summarise new issues in this repo and post them to the task board."
              data-testid="add-routine-instruction"
              class="w-full px-3 py-2 rounded-lg text-body outline-none resize-none font-mono"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
            />
          </div>

          <div class="px-5 pb-3">
            <div class="flex items-baseline justify-between mb-2">
              <label
                class="text-dense font-medium"
                style="color: var(--semantic-text-dim)"
                for="add-routine-schedule"
                >Schedule (cron, UTC)</label
              >
              <span class="text-micro" style="color: var(--semantic-text-dim); opacity: 0.7"
                >empty = manual only</span
              >
            </div>
            <input
              id="add-routine-schedule"
              v-model="schedule"
              type="text"
              placeholder="0 9 * * *"
              data-testid="add-routine-schedule"
              :aria-invalid="scheduleError !== null"
              class="w-full px-3 py-2 rounded-lg text-body outline-none font-mono"
              :style="{
                backgroundColor: 'var(--semantic-sidebar-bg)',
                border: `1px solid ${scheduleError ? 'var(--color-red)' : 'var(--color-border)'}`,
                color: 'var(--semantic-text)',
              }"
              @input="scheduleTouched = true"
              @blur="scheduleTouched = true"
            />
            <div class="flex flex-wrap gap-1.5 mt-2" data-testid="add-routine-presets">
              <button
                v-for="preset in PRESETS"
                :key="preset.label"
                type="button"
                class="px-2 py-1 rounded-md text-micro font-medium"
                :style="
                  activePreset === preset.label
                    ? 'background-color: var(--semantic-active-bg); border: 1px solid var(--color-border); color: var(--semantic-text);'
                    : 'background-color: transparent; border: 1px solid var(--color-border); color: var(--semantic-text-dim);'
                "
                :data-testid="`add-routine-preset-${preset.cron || 'manual'}`"
                @click="applyPreset(preset.cron)"
              >
                {{ preset.label }}
              </button>
            </div>
            <p v-if="scheduleError" class="text-dense mt-1" style="color: var(--color-red)">
              {{ scheduleError }}
            </p>
          </div>

          <div class="px-5 py-4 flex justify-end gap-2" style="border-top: 1px solid var(--color-border)">
            <button
              type="button"
              @click="handleClose"
              data-testid="add-routine-cancel"
              class="px-3 py-1.5 rounded-lg text-body font-medium"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text-muted);
              "
            >
              Cancel
            </button>
            <button
              type="button"
              @click="handleCreate"
              :disabled="!canSubmit"
              data-testid="add-routine-submit"
              class="px-3 py-1.5 rounded-lg text-body font-medium disabled:opacity-50"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
            >
              Add
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>

  <FilePickerDialog
    v-model="showPicker"
    mode="folder"
    :load-items="loadItemsForPicker"
    :key-for="(e: any) => e.path as string"
    :path-for="(e: any) => e.path as string"
    :is-expandable="(e: any) => e.is_directory as boolean"
    :label-for="(e: any) => e.name as string"
    :close-on-select="true"
    title="Select Routine Cwd"
    @select="handleFolderSelected"
  />
</template>

<style scoped>
.add-routine-modal-enter-active,
.add-routine-modal-leave-active {
  transition: opacity 0.2s ease;
}
.add-routine-modal-enter-from,
.add-routine-modal-leave-to {
  opacity: 0;
}
</style>
