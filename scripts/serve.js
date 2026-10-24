// Minimal static server for the demo, with no dependencies. It sends the
// cross-origin isolation headers, so the local demo can run threads (TRD 3);
// everything it serves is same-origin, as require-corp needs.
//
//   npm run demo        builds the core, then serves http://localhost:8080/docs/

import {createServer} from "node:http";
import {readFile} from "node:fs/promises";
import {extname, join, normalize, sep} from "node:path";
import {fileURLToPath} from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const port = +(process.env.PORT || 8080);
const types = {".html": "text/html", ".js": "text/javascript", ".json": "application/json", ".wasm": "application/wasm", ".css": "text/css"};

createServer(async (req, res) => {
  let path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (path === "/" || path === "/demo" || path === "/demo/" || path === "/docs") return void res.writeHead(302, {location: "/docs/"}).end();
  if (path.endsWith("/")) path += "index.html";
  const file = normalize(join(root, path));
  if (!file.startsWith(root.endsWith(sep) ? root : root + sep)) return void res.writeHead(403).end();
  try {
    const body = await readFile(file);
    res.writeHead(200, {
      "content-type": types[extname(file)] || "application/octet-stream",
      "cache-control": "no-store",
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp"
    }).end(body);
  } catch {
    res.writeHead(404).end("not found");
  }
}).listen(port, "127.0.0.1", () => console.log(`demo: http://localhost:${port}/`));
