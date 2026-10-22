import constant from "./constant.js";
import {Slot, slot, MANY_BODY, THETA2, DISTANCE_MIN2, DISTANCE_MAX2, F0} from "./core.js";

export default function() {
  var nodes,
      random,
      strength = constant(-30),
      strengths,
      distanceMin2 = 1,
      distanceMax2 = Infinity,
      theta2 = 0.81,
      s = new Slot(MANY_BODY);

  function force(alpha) {
    s.scalar(THETA2, theta2), s.scalar(DISTANCE_MIN2, distanceMin2), s.scalar(DISTANCE_MAX2, distanceMax2);
    s.run(nodes, alpha, random);
  }

  // The core reads strengths by position; d3 reads strengths[node.index].
  function initialize() {
    if (!nodes) return;
    var i, n = nodes.length, node, a;
    strengths = new Array(n);
    for (i = 0; i < n; ++i) node = nodes[i], strengths[node.index] = +strength(node, i, nodes);
    s.bind(nodes), s.count(n), a = s.f64(F0, n);
    for (i = 0; i < n; ++i) a[i] = strengths[nodes[i].index];
  }

  force[slot] = s;

  force.initialize = function(_nodes, _random) {
    nodes = _nodes;
    random = _random;
    initialize();
  };

  force.strength = function(_) {
    return arguments.length ? (strength = typeof _ === "function" ? _ : constant(+_), initialize(), force) : strength;
  };

  force.distanceMin = function(_) {
    return arguments.length ? (distanceMin2 = _ * _, force) : Math.sqrt(distanceMin2);
  };

  force.distanceMax = function(_) {
    return arguments.length ? (distanceMax2 = _ * _, force) : Math.sqrt(distanceMax2);
  };

  force.theta = function(_) {
    return arguments.length ? (theta2 = _ * _, force) : Math.sqrt(theta2);
  };

  return force;
}
