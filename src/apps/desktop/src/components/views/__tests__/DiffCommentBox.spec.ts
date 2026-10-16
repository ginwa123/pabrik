/** DiffCommentBox: agnostic persistent comment box for diff review. - textarea draft persisted to
 * localStorage under diff-comment:<cwd>:<filePath>:<start>-<end>; reload restores draft - Save
 * persists + emits save with formatted markdown. */
import { describe, expect, it, beforeEach, vi } from "vitest";
import { mount, flushPromises } from "@vue/test-utils";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import DiffCommentBox, {
  buildDraftKey,
  deleteSavedComment,
  formatReviewComment,
  listSavedComments,
} from "../chat_right_sidebar/DiffCommentBox.vue";
import { makeLocalStorageStub } from "../../../__tests__/helpers";

const __dir = dirname(fileURLToPath(import.meta.url));
const boxSrc = readFileSync(
  resolve(__dir, "../chat_right_sidebar/DiffCommentBox.vue"),
  "utf8",
);

const PROPS = {
  filePath: "src/foo.ts",
  startLine: 10,
  endLine: 14,
  context: "10  old\n11 +new",
  cwd: "/repo",
};
const KEY = "diff-comment:/repo:src/foo.ts:10-14";

function installStorage(): void {
  Object.defineProperty(globalThis, "localStorage", {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  });
}

beforeEach(() => {
  installStorage();
  vi.unstubAllGlobals();
});

describe("DiffCommentBox static contract", () => {
  it("never imports FileInput and never calls sendChatMessage", () => {
    expect(boxSrc).not.toMatch(/FileInput/);
    expect(boxSrc).not.toMatch(/sendChatMessage/);
    expect(boxSrc).not.toMatch(/submit-review/);
  });

  it("builds the expected draft key and markdown shape", () => {
    expect(buildDraftKey("/repo", "src/foo.ts", 10, 14)).toBe(KEY);
    const md = formatReviewComment("src/foo.ts", 10, 14, "ctx", "hello");
    expect(md).toContain("## Code Review");
    expect(md).toContain("src/foo.ts");
    expect(md).toContain("Lines 10-14");
    expect(md).toContain("hello");
  });

  it("formats a single-line range as Line N", () => {
    expect(formatReviewComment("f", 7, 7, "ctx", "m")).toContain("Line 7");
  });
});

describe("DiffCommentBox behavior", () => {
  it("save persists to localStorage under the expected key and emits save", async () => {
    const wrapper = mount(DiffCommentBox, { props: PROPS });
    await wrapper.get("[data-testid=diff-comment-input]").setValue("looks good");
    await wrapper.get("[data-testid=diff-comment-save]").trigger("click");
    await flushPromises();
    const raw = localStorage.getItem(KEY);
    expect(raw).not.toBeNull();
    expect(JSON.parse(raw!)).toMatchObject({
      message: "looks good",
      context: "10  old\n11 +new",
    });
    const saved = wrapper.emitted("save");
    expect(saved).toHaveLength(1);
    const payload = saved![0]![0] as Record<string, unknown>;
    expect(payload).toMatchObject({
      filePath: "src/foo.ts",
      startLine: 10,
      endLine: 14,
      message: "looks good",
    });
    expect(String(payload["formatted"])).toContain("looks good");
    expect(String(payload["formatted"])).toContain("## Code Review");
    expect(wrapper.find("[data-testid=diff-comment-saved]").exists()).toBe(true);
  });

  it("reload restores the draft from localStorage", async () => {
    localStorage.setItem(KEY, JSON.stringify({ message: "drafted", savedAt: 1 }));
    const wrapper = mount(DiffCommentBox, { props: PROPS });
    await flushPromises();
    expect(
      (wrapper.get("[data-testid=diff-comment-input]").element as HTMLTextAreaElement).value,
    ).toBe("drafted");
  });

  it("copy writes clipboard with formatted markdown and emits copy", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal("navigator", { clipboard: { writeText } });
    const wrapper = mount(DiffCommentBox, { props: PROPS });
    await wrapper.get("[data-testid=diff-comment-input]").setValue("nit: rename");
    await wrapper.get("[data-testid=diff-comment-copy]").trigger("click");
    await flushPromises();
    expect(writeText).toHaveBeenCalledTimes(1);
    expect(String(writeText.mock.calls[0]![0])).toContain("## Code Review");
    expect(String(writeText.mock.calls[0]![0])).toContain("nit: rename");
    expect(wrapper.emitted("copy")).toHaveLength(1);
    expect(wrapper.find("[data-testid=diff-comment-copied]").exists()).toBe(true);
  });
});

describe("listSavedComments / deleteSavedComment", () => {
  it("returns full entries with message, savedAt and context", () => {
    localStorage.setItem(
      KEY,
      JSON.stringify({ message: "full", savedAt: 42, context: "ctx" }),
    );
    expect(listSavedComments("/repo", "src/foo.ts")).toEqual([
      { start: 10, end: 14, message: "full", savedAt: 42, context: "ctx" },
    ]);
  });

  it("defaults missing context to empty string and keeps legacy values", () => {
    localStorage.setItem(KEY, JSON.stringify({ message: "no-ctx", savedAt: 7 }));
    localStorage.setItem(
      "diff-comment:/repo:src/foo.ts:1-2",
      "legacy raw",
    );
    expect(listSavedComments("/repo", "src/foo.ts")).toEqual([
      { start: 10, end: 14, message: "no-ctx", savedAt: 7, context: "" },
      { start: 1, end: 2, message: "legacy raw", savedAt: 0, context: "" },
    ]);
  });

  it("deleteSavedComment removes the entry", () => {
    localStorage.setItem(KEY, JSON.stringify({ message: "bye", savedAt: 1 }));
    deleteSavedComment("/repo", "src/foo.ts", 10, 14);
    expect(localStorage.getItem(KEY)).toBeNull();
    expect(listSavedComments("/repo", "src/foo.ts")).toEqual([]);
  });
});
