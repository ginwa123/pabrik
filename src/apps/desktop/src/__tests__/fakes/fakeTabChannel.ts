// src/apps/desktop/src/__tests__/fakes/fakeTabChannel.ts In-process stand-in for
// `BroadcastChannel`, so several "tabs" can be simulated inside one vitest worker: * instances
// created with the same name see each other's messages, * the sender never receives its own.
import type { TabChannelLike } from '../../helpers/sseTabChannel'

type MessageListener = (event: { data: unknown }) => void

export interface HubLogEntry {
  from: string
  name: string
  msg: unknown
}

export class FakeTabChannel implements TabChannelLike {
  readonly id: string
  closed = false
  private listeners = new Set<MessageListener>()

  constructor(
    private hub: FakeTabChannelHub,
    readonly name: string,
  ) {
    this.id = `ch_${Math.random().toString(36).slice(2, 8)}`
  }

  postMessage(message: unknown): void {
    if (this.closed) return
    this.hub.deliver(this, message)
  }

  addEventListener(_type: 'message', listener: MessageListener): void {
    this.listeners.add(listener)
  }

  removeEventListener(_type: 'message', listener: MessageListener): void {
    this.listeners.delete(listener)
  }

  close(): void {
    this.closed = true
    this.hub.forget(this)
  }

  /** Hub-side delivery. Kept separate from `postMessage` (which is the API). */
  receive(message: unknown): void {
    if (this.closed) return
    // oxlint-disable-next-line unicorn/no-useless-spread -- snapshot copy: a listener may remove itself during delivery.
    for (const l of [...this.listeners]) l({ data: message })
  }
}

export class FakeTabChannelHub {
  private byName = new Map<string, Set<FakeTabChannel>>()
  /** Every message posted through this hub, in order. */
  readonly log: HubLogEntry[] = []

  /** Pass as `channelFactory` to the coordinator / `installSseBus`. */
  create = (name: string): TabChannelLike => {
    const ch = new FakeTabChannel(this, name)
    let set = this.byName.get(name)
    if (!set) {
      set = new Set()
      this.byName.set(name, set)
    }
    set.add(ch)
    return ch
  }

  /** All live participants on a channel name. */
  members(name: string): FakeTabChannel[] {
    return [...(this.byName.get(name) ?? [])]
  }

  deliver(from: FakeTabChannel, msg: unknown): void {
    this.log.push({ from: from.id, name: from.name, msg })
    const set = this.byName.get(from.name)
    if (!set) return
    for (const ch of set) {
      if (ch === from) continue
      // BroadcastChannel delivery is a task, never synchronous.
      setTimeout(() => ch.receive(msg), 0)
    }
  }

  forget(ch: FakeTabChannel): void {
    this.byName.get(ch.name)?.delete(ch)
  }

  /** Simulate a tab that vanished without a `down` message. */
  kill(ch: FakeTabChannel): void {
    ch.close()
  }

  /** Messages matching a predicate, for assertions. */
  find(pred: (e: HubLogEntry) => boolean): HubLogEntry[] {
    return this.log.filter(pred)
  }

  /** Messages of a given kind (`k`), from any sender. */
  ofKind(k: string): HubLogEntry[] {
    return this.log.filter((e) => (e.msg as { k?: string } | null)?.k === k)
  }
}

/** Let queued channel messages (and coordinator timers) run. */
export function settle(ms = 0): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/** Wait until `pred()` holds (or the deadline passes). */
export async function waitFor(pred: () => boolean, timeoutMs = 600): Promise<void> {
  const start = Date.now()
  while (!pred() && Date.now() - start < timeoutMs) await settle(5)
}

/**  * A minimal "another tab is already leading" participant: answers `who` with `here` and emits
 * periodic `beat`s, so the tab under test stays a follower. Returns a stop function. */
export function fakeForeignLeader(
  hub: FakeTabChannelHub,
  channelName: string,
  opts: { visible?: boolean; beatMs?: number; tabId?: string } = {},
): { stop: () => void; channel: FakeTabChannel } {
  const visible = opts.visible ?? true
  const beatMs = opts.beatMs ?? 10
  const tabId = opts.tabId ?? 'foreign_leader'
  const channel = hub.create(channelName) as FakeTabChannel
  const rank = (visible ? 1e12 : 0) + (1e12 - 1000)
  const beat = (): void => channel.postMessage({ k: 'beat', tabId, visible, rank })
  channel.addEventListener('message', (event) => {
    const msg = event.data as { k?: string; tabId?: string } | null
    if (!msg || msg.k !== 'who') return
    channel.postMessage({ k: 'here', tabId, visible, rank })
  })
  const timer = setInterval(beat, beatMs)
  beat()
  return {
    channel,
    stop: () => {
      clearInterval(timer)
      channel.close()
    },
  }
}
