import constant from "./constant.js";
import {Slot, slot, COLLIDE, STRENGTH, ITERATIONS, F0} from "./core.js";

export default function(radius) {
  var nodes,
      radii,
      random,
      strength = 1,
      iterations = 1,
      s = new Slot(COLLIDE);

  if (typeof radius !== "function") radius = constant(radius == null ? 1 : +radius);

  function force() {
    s.scalar(STRENGTH, strength), s.scalar(ITERATIONS, iterations);
    s.run(nodes, 0, random);
  }

  // The core reads radii by position; d3 reads radii[node.index].
  function initialize() {
    if (!nodes) return;
    var i, n = nodes.length, node, a;
    radii = new Array(n);
    for (i = 0; i < n; ++i) node = nodes[i], radii[node.index] = +radius(node, i, nodes);
    s.bind(nodes), s.count(n), a = s.f64(F0, n);
    for (i = 0; i < n; ++i) a[i] = radii[nodes[i].index];
  }

  force[slot] = s;

  force.initialize = function(_nodes, _random) {
    nodes = _nodes;
    random = _random;
    initialize();
  };

  force.iterations = function(_) {
    return arguments.length ? (iterations = +_, force) : iterations;
  };

  force.strength = function(_) {
    return arguments.length ? (strength = +_, force) : strength;
  };

  force.radius = function(_) {
    return arguments.length ? (radius = typeof _ === "function" ? _ : constant(+_), initialize(), force) : radius;
  };

  return force;
}
