// Failure paths of the pool (TRD 3, Testing: worker trap, worker killed, long
// phase, process lifetime, memory fallback). A failure retires the pool for
// the whole process, so each case runs in a child process of its own.

import {test} from "node:test";
import assert from "node:assert/strict";
import {execFile} from "node:child_process";

function child(name, args = [], timeout = 120000) {
  return new Promise((resolve, reject) => {
    const script = new URL(`./child/${name}.mjs`, import.meta.url).pathname;
    const t0 = performance.now();
    execFile(process.execPath, [script, ...args], {timeout}, (error, stdout, stderr) => {
      if (error) return reject(new Error(`${name}: ${error.message}\n${stderr}`));
      const line = stdout.trim().split("\n").at(-1);
      resolve({...JSON.parse(line), wallMs: performance.now() - t0});
    });
  });
}

test("a worker trap fails over within the tick and keeps d3's bits", async () => {
  const r = await child("trap");
  assert.equal(r.diff, null);
  assert.ok(r.retiredAt >= 5, `retired at tick ${r.retiredAt}`);
  assert.equal(r.status, "retired");
  assert.equal(r.threadsAfter, 0);
});

test("a killed worker never hangs a tick or changes a bit", async () => {
  const r = await child("kill");
  assert.equal(r.diff, null);
  assert.ok(["ready", "retired"].includes(r.status), r.status);
  assert.ok(r.worstTickMs < 5000, `worst tick ${r.worstTickMs} ms`);
});

test("a worker that stalls mid-phase fails over after the no-progress timeout", async () => {
  const r = await child("stall");
  assert.equal(r.diff, null);
  assert.equal(r.status, "retired");
  assert.ok(r.retiredAt >= 3, `retired at tick ${r.retiredAt}`);
  assert.ok(r.worstTickMs < 2000, `worst tick ${r.worstTickMs} ms`);
});

test("a phase longer than the timeout is not a failure", async () => {
  const r = await child("long-phase");
  assert.equal(r.status, "ready");
  assert.equal(r.threads, 1);
  assert.ok(r.tickMs > 30, `tick ${r.tickMs} ms should exceed the 30 ms timeout`);
});

test("a simulation left to its timer ends and the process exits", async () => {
  const r = await child("lifetime", [], 60000);
  assert.equal(r.ended, true);
  assert.ok(r.used > 0, "the pool was used");
});

test("shared memory falls back to 512 MiB, then 128 MiB, then off", async () => {
  for (const [limit, status] of [[16384, "ready"], [8192, "ready"], [2048, "unavailable"]]) {
    const r = await child("memory", [String(limit)]);
    assert.equal(r.diff, null, `limit ${limit}`);
    assert.equal(r.status, status, `limit ${limit}`);
    assert.equal(r.threads > 0, status === "ready", `limit ${limit}: threads ${r.threads}`);
  }
});
