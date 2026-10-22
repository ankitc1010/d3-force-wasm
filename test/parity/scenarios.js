// Parity corpus scenarios (TRD, Testing: "Parity corpus"). Each scenario builds
// a simulation with a given library from a seeded data generator, so d3-force
// and d3-force-wasm see identical inputs; `before(t)` may mutate state ahead of
// tick t, and `ticks` overrides how many ticks one step runs.

// Data generator, independent of the simulations' own random sources.
export function generator(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function xorshift(seed) {
  let s = seed | 0 || 1;
  return () => {
    s ^= s << 13, s ^= s >>> 17, s ^= s << 5;
    return (s >>> 0) / 4294967296;
  };
}

const randomNodes = (n, r, spread = 500) =>
  Array.from({length: n}, () => ({x: (r() - 0.5) * spread, y: (r() - 0.5) * spread}));

const emptyNodes = (n) => Array.from({length: n}, () => ({}));

function randomLinks(n, m, r) {
  const links = [];
  for (let i = 0; i < m; ++i) links.push({source: Math.floor(r() * n), target: Math.floor(r() * n)});
  return links;
}

// Preferential attachment: each new node links to 1 or 2 earlier endpoints.
function scaleFreeLinks(n, r) {
  const links = [], ends = [0];
  for (let i = 1; i < n; ++i) {
    for (let k = r() < 0.3 ? 2 : 1; k > 0; --k) {
      const j = ends[Math.floor(r() * ends.length)];
      links.push({source: i, target: j}), ends.push(i, j);
    }
  }
  return links;
}

function defaults(lib, nodes, links) {
  return lib.forceSimulation(nodes)
      .force("charge", lib.forceManyBody())
      .force("link", lib.forceLink(links))
      .force("center", lib.forceCenter())
      .stop();
}

export const scenarios = {
  // Default forces on a random graph, at several sizes.
  ...Object.fromEntries([10, 100, 1000].map((n) => [`default-forces-${n}`, {
    n, setup(lib, r) {
      const nodes = emptyNodes(n);
      return {sim: defaults(lib, nodes, randomLinks(n, 2 * n, r)), nodes};
    }
  }])),

  "scale-free-collide": {
    setup(lib, r) {
      const nodes = randomNodes(300, r);
      const sim = defaults(lib, nodes, scaleFreeLinks(300, r)).force("collide", lib.forceCollide(4));
      return {sim, nodes};
    }
  },

  "grid": {
    setup(lib) {
      const nodes = Array.from({length: 400}, (_, i) => ({x: i % 20, y: Math.floor(i / 20)}));
      const links = [];
      for (let i = 0; i < 400; ++i) {
        if (i % 20 < 19) links.push({source: i, target: i + 1});
        if (i < 380) links.push({source: i, target: i + 20});
      }
      return {sim: defaults(lib, nodes, links), nodes};
    }
  },

  // Every node coincident: jiggle in manyBody, collide and link.
  "all-at-origin": {
    setup(lib, r) {
      const nodes = Array.from({length: 60}, () => ({x: 0, y: 0}));
      const sim = defaults(lib, nodes, randomLinks(60, 60, r)).force("collide", lib.forceCollide(2));
      return {sim, nodes};
    }
  },

  "coincident-groups": {
    setup(lib, r) {
      const nodes = Array.from({length: 120}, (_, i) => ({x: (i % 6) * 10, y: (i % 4) * 10}));
      const sim = defaults(lib, nodes, randomLinks(120, 100, r)).force("collide", lib.forceCollide(3));
      return {sim, nodes};
    }
  },

  "near-1e300": {
    setup(lib, r) {
      const nodes = Array.from({length: 50}, () => ({x: 1e300 * (r() - 0.5), y: 1e300 * (r() - 0.5)}));
      return {sim: defaults(lib, nodes, randomLinks(50, 40, r)), nodes};
    }
  },

  // Closer than 2^-32 of the extent: the tree's fallback below Morton resolution.
  "near-duplicates": {
    setup(lib, r) {
      const nodes = Array.from({length: 80}, (_, i) => i < 4
        ? {x: i * 300, y: i * 300}
        : {x: 0.5 + Math.floor(r() * 6) * 1e-12, y: 0.25 + Math.floor(r() * 6) * 3e-13});
      const sim = defaults(lib, nodes, randomLinks(80, 40, r)).force("collide", lib.forceCollide(1));
      return {sim, nodes};
    }
  },

  // Each force alone.
  "only-center": {setup: (lib, r) => single(lib, r, lib.forceCenter(30 * r(), -20 * r()).strength(0.7))},
  "only-collide": {setup: (lib, r) => single(lib, r, lib.forceCollide(12))},
  "only-link": {
    setup(lib, r) {
      const nodes = randomNodes(150, r);
      return {sim: lib.forceSimulation(nodes).force("link", lib.forceLink(randomLinks(150, 300, r))).stop(), nodes};
    }
  },
  "only-many-body": {setup: (lib, r) => single(lib, r, lib.forceManyBody())},
  "only-radial": {setup: (lib, r) => single(lib, r, lib.forceRadial(100, 10 * r(), 5))},
  "only-x": {setup: (lib, r) => single(lib, r, lib.forceX(50 * r()))},
  "only-y": {setup: (lib, r) => single(lib, r, lib.forceY(-50 * r()))},

  // Every accessor as a function.
  "accessors-as-functions": {
    setup(lib, r) {
      const nodes = randomNodes(200, r).map((d, i) => ({...d, id: "n" + i, w: 1 + (i % 7), g: i % 3}));
      const links = randomLinks(200, 300, r).map((l) => ({source: "n" + l.source, target: "n" + l.target, w: 1 + (l.source % 5)}));
      const sim = lib.forceSimulation(nodes)
          .force("charge", lib.forceManyBody().strength((d) => -10 * d.w))
          .force("link", lib.forceLink(links).id((d) => d.id).distance((l) => 10 * l.w).strength((l) => 1 / l.w))
          .force("collide", lib.forceCollide((d) => d.w))
          .force("x", lib.forceX((d) => d.g * 100).strength((d) => 0.01 * d.w))
          .force("y", lib.forceY((d) => -d.g * 50).strength(0.05))
          .force("radial", lib.forceRadial((d) => 50 * d.g, 5, 5).strength((d) => d.w / 70))
          .stop();
      return {sim, nodes};
    }
  },

  // NaN from accessors propagates as in d3.
  "nan-accessors": {
    setup(lib, r) {
      const nodes = randomNodes(100, r);
      const sim = lib.forceSimulation(nodes)
          .force("charge", lib.forceManyBody().strength((d, i) => i % 13 === 0 ? NaN : -20))
          .force("collide", lib.forceCollide((d, i) => i % 11 === 0 ? NaN : 3))
          .force("x", lib.forceX((d, i) => i % 7 === 0 ? NaN : 0))
          .force("radial", lib.forceRadial((d, i) => i % 5 === 0 ? NaN : 80))
          .stop();
      return {sim, nodes};
    }
  },

  "nan-link-distance": {
    setup(lib, r) {
      const nodes = randomNodes(60, r);
      const sim = lib.forceSimulation(nodes)
          .force("link", lib.forceLink(randomLinks(60, 50, r)).distance((l, i) => i === 3 ? NaN : 20))
          .stop();
      return {sim, nodes};
    }
  },

  // An exact tie in `w * w / theta2 < l` on an internal cell: (0,0) and (4,0)
  // share the 8-wide cell with centroid (2,0), and from (2,16) with theta 0.5,
  // w² / θ² = 256 = l. (Ties on leaves are invisible: approximating a single
  // point at power-of-two distances rounds the same as the direct sum.)
  "many-body-exact-tie": {
    setup(lib) {
      const nodes = [{x: 0, y: 0}, {x: 4, y: 0}, {x: 2, y: 16}];
      return {sim: lib.forceSimulation(nodes).force("f", lib.forceManyBody().theta(0.5)).stop(), nodes};
    }
  },

  // Infinite endpoints make link deltas NaN, which `|| jiggle` also catches.
  "link-infinite-positions": {
    setup(lib, r) {
      const nodes = randomNodes(30, r).map((d, i) => i < 6 ? {x: i % 2 ? Infinity : -Infinity, y: Infinity} : d);
      const links = randomLinks(30, 30, r).concat([{source: 0, target: 2}, {source: 1, target: 3}, {source: 4, target: 5}]);
      return {sim: lib.forceSimulation(nodes).force("link", lib.forceLink(links)).stop(), nodes};
    }
  },

  "many-body-theta-0":{setup: (lib, r) => single(lib, r, lib.forceManyBody().theta(0), 120)},
  "many-body-theta-infinity": {setup: (lib, r) => single(lib, r, lib.forceManyBody().theta(Infinity), 120)},
  "many-body-distance-max": {setup: (lib, r) => single(lib, r, lib.forceManyBody().distanceMax(60).distanceMin(5), 300)},

  "fx-fy-toggling": {
    setup(lib, r) {
      const nodes = randomNodes(150, r);
      const sim = defaults(lib, nodes, randomLinks(150, 200, r));
      const before = (t) => {
        for (let i = 0; i < nodes.length; ++i) {
          const d = nodes[i], k = (i * 7 + t) % 11;
          if (k === 0) d.fx = d.x + 1;
          else if (k === 1) d.fx = null;
          else if (k === 2) d.fy = 0;
          else if (k === 3) delete d.fy;
          else if (k === 4) d.fx = undefined;
        }
      };
      return {sim, nodes, before};
    }
  },

  // A custom force between two native ones sees current node objects.
  "custom-force-between": {
    setup(lib, r) {
      const nodes = randomNodes(150, r);
      const sim = lib.forceSimulation(nodes)
          .force("charge", lib.forceManyBody())
          .force("swirl", (alpha) => {
            for (const d of nodes) d.vx += -d.y * 0.001 * alpha, d.vy += d.x * 0.001 * alpha;
          })
          .force("link", lib.forceLink(randomLinks(150, 150, r)))
          .force("custom2", () => { for (const d of nodes) if (d.index % 9 === 0) d.x += 0.5; })
          .force("center", lib.forceCenter())
          .stop();
      return {sim, nodes};
    }
  },

  // nodes() with a longer, then a shorter array mid-run.
  "nodes-resize": {
    setup(lib, r) {
      let nodes = randomNodes(100, r);
      const extra = randomNodes(80, r);
      const sim = lib.forceSimulation(nodes)
          .force("charge", lib.forceManyBody())
          .force("collide", lib.forceCollide(5))
          .force("x", lib.forceX())
          .stop();
      const state = {sim, get nodes() { return nodes; }};
      state.before = (t) => {
        if (t === 50) sim.nodes(nodes = nodes.concat(extra));
        if (t === 150) sim.nodes(nodes = nodes.slice(30));
      };
      return state;
    }
  },

  "random-source-xorshift": {
    setup(lib, r) {
      const nodes = Array.from({length: 40}, () => ({x: 0, y: 0}));
      const sim = defaults(lib, nodes, randomLinks(40, 30, r))
          .force("collide", lib.forceCollide(2))
          .randomSource(xorshift(Math.floor(r() * 2 ** 31)));
      return {sim, nodes};
    }
  },

  // Zero-length links: self-loops and coincident endpoints.
  "zero-length-links": {
    setup(lib, r) {
      const nodes = randomNodes(40, r).map((d, i) => i < 10 ? {x: 0, y: 0} : d);
      const links = randomLinks(40, 40, r).concat(Array.from({length: 10}, (_, i) => ({source: i, target: (i + 1) % 10})), [{source: 20, target: 20}]);
      return {sim: lib.forceSimulation(nodes).force("link", lib.forceLink(links)).stop(), nodes};
    }
  },

  "iterations-and-parameters": {
    setup(lib, r) {
      const nodes = randomNodes(200, r);
      const sim = lib.forceSimulation(nodes)
          .force("charge", lib.forceManyBody().strength(-15).theta(0.5))
          .force("link", lib.forceLink(randomLinks(200, 250, r)).iterations(2).distance(15))
          .force("collide", lib.forceCollide(6).iterations(3).strength(0.7))
          .alphaDecay(0.01)
          .alphaTarget(0.2)
          .velocityDecay(0.25)
          .stop();
      return {sim, nodes};
    }
  },

  // tick(n) batches: one copy-in and copy-out around several ticks.
  "batched-ticks": {
    ticks: 7,
    setup(lib, r) {
      const nodes = emptyNodes(200);
      return {sim: defaults(lib, nodes, randomLinks(200, 300, r)).force("collide", lib.forceCollide(3)), nodes};
    }
  },

  "nan-initial-positions": {
    setup(lib, r) {
      const nodes = randomNodes(100, r).map((d, i) => i % 4 === 0 ? {y: d.y} : i % 4 === 1 ? {x: d.x, vx: NaN} : d);
      return {sim: defaults(lib, nodes, randomLinks(100, 120, r)).force("collide", lib.forceCollide(2)), nodes};
    }
  }
};

function single(lib, r, force, n = 200) {
  const nodes = randomNodes(n, r);
  return {sim: lib.forceSimulation(nodes).force("f", force).stop(), nodes};
}
