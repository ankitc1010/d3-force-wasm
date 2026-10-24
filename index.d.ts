// d3-force-wasm has d3-force's API plus a few optional extensions, so it reuses
// d3-force's types (install @types/d3-force).
import type {Simulation as D3Simulation, SimulationNodeDatum, SimulationLinkDatum} from "d3-force";

export * from "d3-force";

export interface FastOptions {
  /** Fast multipole order p (1–24, default 8). Higher is more accurate and slower. */
  order?: number;
  /** Opening parameter κ (> 1, default 1.5). Larger means more direct pairs and more accuracy. */
  opening?: number;
}

export interface Simulation<NodeDatum extends SimulationNodeDatum, LinkDatum extends SimulationLinkDatum<NodeDatum> | undefined>
  extends D3Simulation<NodeDatum, LinkDatum> {
  /** Current precision mode: "exact" (bit-exact d3-force, the default) or "fast" (O(n) kernels). */
  precision(): "exact" | "fast";
  precision(mode: "exact" | "fast", options?: FastOptions): this;
  /** Workers the last tick used: 0 on one thread (below 2,000 nodes, without cross-origin isolation, or while the pool loads). */
  threads(): number;
  /** Caps the workers a tick may use: 0 keeps the simulation on one thread, null restores auto (hardwareConcurrency − 1). Results are the same bits at any setting. */
  threads(workers: number | null): this;
}

export interface ConfigureOptions {
  /** Where to fetch the threaded core, core-mt.wasm (default: next to the module). */
  coreURL?: string | URL;
  /** Where to fetch the pool's worker script, worker.js (default: next to the module). */
  workerURL?: string | URL;
}

/** Overrides where the threaded core and its worker are fetched from; call before the first threaded tick. */
export function configure(options: ConfigureOptions): void;

export function forceSimulation<NodeDatum extends SimulationNodeDatum>(nodesData?: NodeDatum[]): Simulation<NodeDatum, undefined>;
export function forceSimulation<NodeDatum extends SimulationNodeDatum, LinkDatum extends SimulationLinkDatum<NodeDatum>>(nodesData?: NodeDatum[]): Simulation<NodeDatum, LinkDatum>;
