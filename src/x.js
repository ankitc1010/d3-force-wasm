import constant from "./constant.js";
import {Slot, slot, X, F0, F1} from "./core.js";

export default function(x) {
  var strength = constant(0.1),
      nodes,
      strengths,
      xz,
      s = new Slot(X);

  if (typeof x !== "function") x = constant(x == null ? 0 : +x);

  function force(alpha) {
    s.run(nodes, alpha);
  }

  function initialize() {
    if (!nodes) return;
    var i, n = nodes.length;
    strengths = new Array(n);
    xz = new Array(n);
    for (i = 0; i < n; ++i) {
      strengths[i] = isNaN(xz[i] = +x(nodes[i], i, nodes)) ? 0 : +strength(nodes[i], i, nodes);
    }
    s.bind(nodes), s.count(n);
    s.f64(F0, n).set(strengths), s.f64(F1, n).set(xz);
  }

  force[slot] = s;

  force.initialize = function(_) {
    nodes = _;
    initialize();
  };

  force.strength = function(_) {
    return arguments.length ? (strength = typeof _ === "function" ? _ : constant(+_), initialize(), force) : strength;
  };

  force.x = function(_) {
    return arguments.length ? (x = typeof _ === "function" ? _ : constant(+_), initialize(), force) : x;
  };

  return force;
}
