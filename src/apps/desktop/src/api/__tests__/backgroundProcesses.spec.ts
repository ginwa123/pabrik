/** Tests for the session background-process API fns. Backend: background_processes_list.zig +
 * background_process_log_get.zig (commit b69111f7). */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { ApiError, getBackgroundProcessLog, getBackgroundProcesses } from '../index'

function apiIndexSource(): string {
  const cands = [
    join(process.cwd(), 'src/api/index.ts'), // cwd = src/apps/desktop
    join(process.cwd(), 'src/apps/desktop/src/api/index.ts'), // cwd = repo root
  ]
  try {
    cands.unshift(join(dirname(fileURLToPath(import.meta.url)), '../index.ts'))
  } catch {
    // vite-rewritten import.meta.url — fall through to cwd candidates.
  }
  const hit = cands.find((p) => existsSync(p))
  if (!hit) throw new Error(`api/index.ts not found (tried ${cands.join(', ')})`)
  return readFileSync(hit, 'utf8')
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('getBackgroundProcesses', () => {
  it('hits the list endpoint with an encoded session id', async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ processes: [], count: 0 }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await getBackgroundProcesses('sess 1/2')
    expect(data).toEqual({ processes: [], count: 0 })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url] = fetchMock.mock.calls[0] as unknown as [string]
    expect(url).toBe('/api/llm/session/sess%201%2F2/background_processes')
  })

  it('returns rows with the live running flag', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () =>
        jsonResponse({
          processes: [
            {
              pid: 4242,
              command: 'sleep 10',
              log_path: '/tmp/bg-4242.log',
              started_at: 1700000000,
              status: 'running',
              running: true,
            },
          ],
          count: 1,
        }),
      ),
    )

    const data = await getBackgroundProcesses('sess_1')
    expect(data.count).toBe(1)
    expect(data.processes[0]).toMatchObject({ pid: 4242, running: true })
  })
})

describe('getBackgroundProcessLog', () => {
  it('defaults max_bytes to 20480', async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        pid: 4242,
        log_path: '/tmp/bg-4242.log',
        total_bytes: 9,
        truncated: false,
        content: 'hello log',
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await getBackgroundProcessLog('sess_1', 4242)
    expect(data.content).toBe('hello log')
    expect(data.truncated).toBe(false)
    const [url] = fetchMock.mock.calls[0] as unknown as [string]
    expect(url).toBe(
      '/api/llm/session/sess_1/background_processes/4242/log?max_bytes=20480',
    )
  })

  it('passes a custom max_bytes through', async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        pid: 4243,
        log_path: '/tmp/bg-4243.log',
        total_bytes: 300,
        truncated: true,
        content: 'TAIL',
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await getBackgroundProcessLog('sess_1', 4243, 100)
    expect(data.truncated).toBe(true)
    const [url] = fetchMock.mock.calls[0] as unknown as [string]
    expect(url).toContain('max_bytes=100')
  })

  it('surfaces the missing-log marker content as-is', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () =>
        jsonResponse({
          pid: 4244,
          log_path: '/tmp/bg-missing.log',
          total_bytes: 0,
          truncated: false,
          content: '(log file not found)',
        }),
      ),
    )

    const data = await getBackgroundProcessLog('sess_1', 4244)
    expect(data.content).toBe('(log file not found)')
    expect(data.total_bytes).toBe(0)
  })

  it('throws ApiError 404 for an unknown pid (silent: no toast, caller renders inline)', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse({ error: 'background process not found' }, 404)),
    )

    await expect(getBackgroundProcessLog('sess_1', 9999)).rejects.toMatchObject({
      name: 'ApiError',
      status: 404,
    })
    // ApiError class identity (not just shape) — the component narrows
    // on `instanceof ApiError` for the 404 message.
    await expect(getBackgroundProcessLog('sess_1', 9999)).rejects.toBeInstanceOf(
      ApiError,
    )
  })
})

describe('background-process API wiring (static contract)', () => {
  const src = apiIndexSource()

  it('declares the BackgroundProcess / list / log response types', () => {
    expect(src).toMatch(/export interface BackgroundProcess\b/)
    expect(src).toMatch(/export interface BackgroundProcessListResponse/)
    expect(src).toMatch(/export interface BackgroundProcessLogResponse/)
  })

  it('declares getBackgroundProcesses + getBackgroundProcessLog', () => {
    expect(src).toMatch(/export async function getBackgroundProcesses/)
    expect(src).toMatch(/export async function getBackgroundProcessLog/)
  })

  it('hits the exact backend routes (list + :pid/log tail)', () => {
    expect(src).toContain('/background_processes`')
    expect(src).toContain('/background_processes/${pid}/log')
  })

  it('polls silently (no toast spam on the 5s / 2s intervals)', () => {
    const listFn = src.slice(src.indexOf('export async function getBackgroundProcesses'))
    const logFn = src.slice(src.indexOf('export async function getBackgroundProcessLog'))
    expect(listFn).toContain('silent: true')
    expect(logFn).toContain('silent: true')
  })
})
