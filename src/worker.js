// One pool worker (TRD 3, Facade): instantiates the threaded core on the
// page's shared memory and runs its job loop until the pool is retired. A trap
// is recorded in shared memory, because during a phase the main thread spins
// inside wasm and cannot receive this worker's error event.

function run({module, memory, tid, region, failed}, post) {
  const env = {
    memory,
    random() { throw new Error("random() called on a pool worker"); },
    now: () => performance.now()
  };
  const core = new WebAssembly.Instance(module, {env}).exports;
  post("started");
  try {
    core.worker_start(tid, region);
  } catch (error) {
    Atomics.store(new Int32Array(memory.buffer, failed, 1), 0, tid);
    throw error;
  }
}

if (typeof WorkerGlobalScope !== "undefined" && self instanceof WorkerGlobalScope) {
  self.onmessage = (event) => run(event.data, (message) => self.postMessage(message));
} else {
  const {parentPort} = await import("node:worker_threads");
  parentPort.once("message", (data) => run(data, (message) => parentPort.postMessage(message)));
}
