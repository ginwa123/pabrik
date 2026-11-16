// ─── Mock EventSource ────────────────────────────────────────────────────
export interface MockEventSource {
  url: string
  readyState: number
  onerror: ((e: Event) => void) | null
  close: () => void
  addEventListener: (type: string, listener: EventListenerOrEventListenerObject) => void
  removeEventListener: (type: string, listener: EventListenerOrEventListenerObject) => void
  emit(type: 'open' | 'error' | 'message' | string, data?: string): void
  /** Simulate the server's `connected` named event. */
  simulateOpen(payload?: string): void
  /** All listeners, by type. */
  _listeners: Map<string, Set<EventListenerOrEventListenerObject>>
  _closed: boolean
}

export function createMockCtor(): {
  ctor: typeof EventSource
  instances: MockEventSource[]
} {
  const instances: MockEventSource[] = []
  const ctor = function MockEventSource(this: unknown, url: string): MockEventSource {
    const inst: MockEventSource = {
      url,
      readyState: 0,
      onerror: null,
      _listeners: new Map(),
      _closed: false,
      close() {
        this._closed = true
        this.readyState = 2
      },
      addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
        let set = this._listeners.get(type)
        if (!set) {
          set = new Set()
          this._listeners.set(type, set)
        }
        set.add(listener)
      },
      removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
        const set = this._listeners.get(type)
        if (set) set.delete(listener)
      },
      emit(type: string, data?: string) {
        // Build a real MessageEvent if the type is message-like.
        const ev = data !== undefined ? new MessageEvent(type, { data }) : new Event(type)
        // Fire addEventListener-style listeners, if any.
        const set = this._listeners.get(type)
        if (set) {
          for (const listener of set) {
            if (typeof listener === 'function') listener(ev)
            else listener.handleEvent(ev)
          }
        }
        // Also fire onerror (the property, not the listener) for parity with the native EventSource behavior.
        if (type === 'error' && this.onerror) {
          this.onerror(ev)
        }
      },
      simulateOpen(payload: string = '{"ok":true}') {
        this.emit('connected', payload)
      },
    }
    instances.push(inst)
    return inst
  } as unknown as typeof EventSource
  return { ctor: ctor as unknown as typeof EventSource, instances }
}

// ─── Mock visibility / online targets ───────────────────────────────────
export function createMockTarget(hidden = false): {
  target: Pick<Document, 'addEventListener' | 'removeEventListener' | 'hidden'> & {
    _listeners: Map<string, Set<EventListenerOrEventListenerObject>>
    setHidden(v: boolean): void
    fire(type: string): void
  }
} {
  const target = {
    hidden,
    _listeners: new Map<string, Set<EventListenerOrEventListenerObject>>(),
    addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      let set = this._listeners.get(type)
      if (!set) {
        set = new Set()
        this._listeners.set(type, set)
      }
      set.add(listener)
    },
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      const set = this._listeners.get(type)
      if (set) set.delete(listener)
    },
    setHidden(v: boolean) {
      this.hidden = v
    },
    fire(type: string) {
      const set = this._listeners.get(type)
      if (!set) return
      for (const listener of set) {
        if (typeof listener === 'function') listener(new Event(type))
        else listener.handleEvent(new Event(type))
      }
    },
  }
  return { target }
}

export function createMockOnlineTarget(): {
  target: Pick<Window, 'addEventListener' | 'removeEventListener'> & {
    _listeners: Map<string, Set<EventListenerOrEventListenerObject>>
    fire(type: string): void
  }
} {
  return {
    target: {
      _listeners: new Map<string, Set<EventListenerOrEventListenerObject>>(),
      addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
        let set = this._listeners.get(type)
        if (!set) {
          set = new Set()
          this._listeners.set(type, set)
        }
        set.add(listener)
      },
      removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
        const set = this._listeners.get(type)
        if (set) set.delete(listener)
      },
      fire(type: string) {
        const set = this._listeners.get(type)
        if (!set) return
        for (const listener of set) {
          if (typeof listener === 'function') listener(new Event(type))
          else listener.handleEvent(new Event(type))
        }
      },
    },
  }
}

// Mock `window` for the `pagehide` / `beforeunload` listeners.
export function createMockUnloadTarget(): {
  target: Pick<Window, 'addEventListener' | 'removeEventListener'> & {
    _listeners: Map<string, Set<EventListenerOrEventListenerObject>>
    fire(type: string): void
  }
} {
  return {
    target: {
      _listeners: new Map<string, Set<EventListenerOrEventListenerObject>>(),
      addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
        let set = this._listeners.get(type)
        if (!set) {
          set = new Set()
          this._listeners.set(type, set)
        }
        set.add(listener)
      },
      removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
        const set = this._listeners.get(type)
        if (set) set.delete(listener)
      },
      fire(type: string) {
        const set = this._listeners.get(type)
        if (!set) return
        for (const listener of set) {
          if (typeof listener === 'function') listener(new Event(type))
          else listener.handleEvent(new Event(type))
        }
      },
    },
  }
}
