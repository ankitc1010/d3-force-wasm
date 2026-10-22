import {Slot, slot, CENTER, STRENGTH, CX, CY} from "./core.js";

export default function(x, y) {
  var nodes, strength = 1, s = new Slot(CENTER);

  if (x == null) x = 0;
  if (y == null) y = 0;

  function force() {
    s.scalar(CX, x), s.scalar(CY, y), s.scalar(STRENGTH, strength);
    s.run(nodes, 0);
  }

  force[slot] = s;

  force.initialize = function(_) {
    nodes = _;
    s.bind(nodes);
  };

  force.x = function(_) {
    return arguments.length ? (x = +_, force) : x;
  };

  force.y = function(_) {
    return arguments.length ? (y = +_, force) : y;
  };

  force.strength = function(_) {
    return arguments.length ? (strength = +_, force) : strength;
  };

  return force;
}
