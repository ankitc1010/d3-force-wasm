import constant from "./constant.js";
import {Slot, slot, Y, F0, F1} from "./core.js";

export default function(y) {
  var strength = constant(0.1),
      nodes,
      strengths,
      yz,
      s = new Slot(Y);

  if (typeof y !== "function") y = constant(y == null ? 0 : +y);

  function force(alpha) {
    s.run(nodes, alpha);
  }

  function initialize() {
    if (!nodes) return;
    var i, n = nodes.length;
    strengths = new Array(n);
    yz = new Array(n);
    for (i = 0; i < n; ++i) {
      strengths[i] = isNaN(yz[i] = +y(nodes[i], i, nodes)) ? 0 : +strength(nodes[i], i, nodes);
    }
    s.bind(nodes), s.count(n);
    s.f64(F0, n).set(strengths), s.f64(F1, n).set(yz);
  }

  force[slot] = s;

  force.initialize = function(_) {
    nodes = _;
    initialize();
  };

  force.strength = function(_) {
    return arguments.length ? (strength = typeof _ === "function" ? _ : constant(+_), initialize(), force) : strength;
  };

  force.y = function(_) {
    return arguments.length ? (y = typeof _ === "function" ? _ : constant(+_), initialize(), force) : y;
  };

  return force;
}
