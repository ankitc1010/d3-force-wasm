import constant from "./constant.js";
import {Slot, slot, RADIAL, CX, CY, F0, F1} from "./core.js";

export default function(radius, x, y) {
  var nodes,
      strength = constant(0.1),
      strengths,
      radiuses,
      s = new Slot(RADIAL);

  if (typeof radius !== "function") radius = constant(+radius);
  if (x == null) x = 0;
  if (y == null) y = 0;

  function force(alpha) {
    s.scalar(CX, x), s.scalar(CY, y);
    s.run(nodes, alpha);
  }

  function initialize() {
    if (!nodes) return;
    var i, n = nodes.length;
    strengths = new Array(n);
    radiuses = new Array(n);
    for (i = 0; i < n; ++i) {
      radiuses[i] = +radius(nodes[i], i, nodes);
      strengths[i] = isNaN(radiuses[i]) ? 0 : +strength(nodes[i], i, nodes);
    }
    s.bind(nodes), s.count(n);
    s.f64(F0, n).set(strengths), s.f64(F1, n).set(radiuses);
  }

  force[slot] = s;

  force.initialize = function(_) {
    nodes = _, initialize();
  };

  force.strength = function(_) {
    return arguments.length ? (strength = typeof _ === "function" ? _ : constant(+_), initialize(), force) : strength;
  };

  force.radius = function(_) {
    return arguments.length ? (radius = typeof _ === "function" ? _ : constant(+_), initialize(), force) : radius;
  };

  force.x = function(_) {
    return arguments.length ? (x = +_, force) : x;
  };

  force.y = function(_) {
    return arguments.length ? (y = +_, force) : y;
  };

  return force;
}
