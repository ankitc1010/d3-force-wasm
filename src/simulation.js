import {dispatch} from "./dispatch.js";
import {timer} from "./timer.js";
import lcg from "./lcg.js";
import {context, slot} from "./core.js";

export function x(d) {
  return d.x;
}

export function y(d) {
  return d.y;
}

var initialRadius = 10,
    initialAngle = Math.PI * (3 - Math.sqrt(5));

export default function(nodes) {
  var simulation,
      alpha = 1,
      alphaMin = 0.001,
      alphaDecay = 1 - Math.pow(alphaMin, 1 / 300),
      alphaTarget = 0,
      velocityDecay = 0.6,
      forces = new Map(),
      stepper = timer(step),
      event = dispatch("tick", "end"),
      random = lcg(),
      precision = "exact",
      fastOptions = null, // {order, opening} while precision is "fast"
      threads = null, // most workers a tick may use; null = auto (TRD 3)
      workersUsed = 0;

  if (nodes == null) nodes = [];

  function step() {
    tick();
    event.call("tick", simulation);
    if (alpha < alphaMin) {
      stepper.stop();
      event.call("end", simulation);
    }
  }

  // d3's tick with the per-node loops in the core. Positions are copied in
  // once, native forces run back to back on the core's arrays, a custom force
  // sees the node objects through a copy-out and copy-in around it, and the
  // result is copied out once at the end. On the threaded core, `hold` keeps
  // the workers spinning for the whole tick (TRD 3, Facade: "Per tick").
  function tick(iterations) {
    var ctx, k, core, active;

    if (iterations === undefined) iterations = 1;
    if (!(0 < iterations)) return simulation;

    ctx = context(nodes);
    ctx.precision = fastOptions;
    workersUsed = ctx.engage(nodes.length, threads);
    core = ctx.core;
    if (core.threaded) active = core.exports.pool_set_active(workersUsed), core.exports.pool_hold(1);
    ctx.copyIn(nodes);
    ctx.live = true;
    try {
      for (k = 0; k < iterations; ++k) {
        alpha += (alphaTarget - alpha) * alphaDecay;

        forces.forEach(function(force) {
          var s = force[slot];
          if (s && s.ctx === ctx) return void force(alpha);
          ctx.live = false;
          ctx.copyOut(nodes);
          try {
            force(alpha);
          } finally {
            ctx.copyIn(nodes);
            ctx.live = true;
          }
        });

        ctx.integrate(velocityDecay);
      }
    } finally {
      ctx.live = false;
      ctx.copyOut(nodes);
      if (core.threaded) core.exports.pool_hold(-1), core.exports.pool_set_active(active);
      if (!ctx.core.threaded) workersUsed = 0;
    }

    return simulation;
  }

  function initializeNodes() {
    for (var i = 0, n = nodes.length, node; i < n; ++i) {
      node = nodes[i], node.index = i;
      if (node.fx != null) node.x = node.fx;
      if (node.fy != null) node.y = node.fy;
      if (isNaN(node.x) || isNaN(node.y)) {
        var radius = initialRadius * Math.sqrt(0.5 + i), angle = i * initialAngle;
        node.x = radius * Math.cos(angle);
        node.y = radius * Math.sin(angle);
      }
      if (isNaN(node.vx) || isNaN(node.vy)) {
        node.vx = node.vy = 0;
      }
    }
  }

  function initializeForce(force) {
    if (force.initialize) force.initialize(nodes, random);
    return force;
  }

  initializeNodes();

  simulation = {
    tick: tick,

    restart: function() {
      return stepper.restart(step), simulation;
    },

    stop: function() {
      return stepper.stop(), simulation;
    },

    nodes: function(_) {
      return arguments.length ? (nodes = _, initializeNodes(), forces.forEach(initializeForce), simulation) : nodes;
    },

    alpha: function(_) {
      return arguments.length ? (alpha = +_, simulation) : alpha;
    },

    alphaMin: function(_) {
      return arguments.length ? (alphaMin = +_, simulation) : alphaMin;
    },

    alphaDecay: function(_) {
      return arguments.length ? (alphaDecay = +_, simulation) : +alphaDecay;
    },

    alphaTarget: function(_) {
      return arguments.length ? (alphaTarget = +_, simulation) : alphaTarget;
    },

    velocityDecay: function(_) {
      return arguments.length ? (velocityDecay = 1 - _, simulation) : 1 - velocityDecay;
    },

    randomSource: function(_) {
      return arguments.length ? (random = _, forces.forEach(initializeForce), simulation) : random;
    },

    force: function(name, _) {
      return arguments.length > 1 ? ((_ == null ? forces.delete(name) : forces.set(name, initializeForce(_))), simulation) : forces.get(name);
    },

    find: function(x, y, radius) {
      var i = 0,
          n = nodes.length,
          dx,
          dy,
          d2,
          node,
          closest;

      if (radius == null) radius = Infinity;
      else radius *= radius;

      for (i = 0; i < n; ++i) {
        node = nodes[i];
        dx = x - node.x;
        dy = y - node.y;
        d2 = dx * dx + dy * dy;
        if (d2 < radius) closest = node, radius = d2;
      }

      return closest;
    },

    on: function(name, _) {
      return arguments.length > 1 ? (event.on(name, _), simulation) : event.on(name);
    }
  };

  // Extensions are non-enumerable so the object's keys stay d3-force's.
  // precision("fast", {order, opening}) selects the O(n) kernels (TRD 2).
  Object.defineProperty(simulation, "precision", {
    configurable: true, writable: true, enumerable: false,
    value: function(mode, options) {
      if (!arguments.length) return precision;
      if (mode !== "exact" && mode !== "fast") throw new Error("precision must be \"exact\" or \"fast\"");
      precision = mode;
      fastOptions = mode === "fast" ? {
        order: Math.min(24, Math.max(1, Math.round(+(options && options.order) || 8))),
        opening: Math.max(1.01, +(options && options.opening) || 1.5)
      } : null;
      context(nodes).precision = fastOptions;
      return simulation;
    }
  });

  // threads(k) caps the workers a tick may use: 0 keeps the simulation on one
  // thread, null restores auto. The getter returns the workers the last tick
  // used: 0 below the threshold, without the pool, or after a failure (TRD 3).
  Object.defineProperty(simulation, "threads", {
    configurable: true, writable: true, enumerable: false,
    value: function(k) {
      if (!arguments.length) return workersUsed;
      threads = k == null ? null : Math.max(0, Math.floor(+k) || 0);
      return simulation;
    }
  });

  return simulation;
}
