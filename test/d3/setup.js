// d3-force's own test suite runs unchanged except for its import path; it is
// written for mocha, so map mocha's global `it` onto node:test.
import {it} from "node:test";

globalThis.it = it;
