// d3-force-wasm has d3-force's API plus one optional extension, so it reuses
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
}

export function forceSimulation<NodeDatum extends SimulationNodeDatum>(nodesData?: NodeDatum[]): Simulation<NodeDatum, undefined>;
export function forceSimulation<NodeDatum extends SimulationNodeDatum, LinkDatum extends SimulationLinkDatum<NodeDatum>>(nodesData?: NodeDatum[]): Simulation<NodeDatum, LinkDatum>;
