import { connect } from "node:net";
import { networkInterfaces } from "node:os";
import { spawn } from "node:child_process";

const script = process.argv[2];
if (!script) throw new Error("usage: agent-canvas-ingress-smoke.mjs <ingress.mjs>");

const port = 18080;
const child = spawn(process.execPath, [script, "--port", String(port), "--default", "http://127.0.0.1:9"], {
  stdio: ["ignore", "pipe", "pipe"],
});
let output = "";
child.stdout.on("data", (chunk) => { output += chunk; });
child.stderr.on("data", (chunk) => { output += chunk; });

function connectTo(host) {
  return new Promise((resolve, reject) => {
    const socket = connect({ host, port });
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error(`connection to ${host} timed out`));
    }, 2_000);
    socket.once("connect", () => { clearTimeout(timer); socket.destroy(); resolve(); });
    socket.once("error", (error) => { clearTimeout(timer); resolve(error); });
  });
}

try {
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`ingress did not start: ${output}`)), 5_000);
    const ready = () => {
      if (output.includes("Listening on:")) { clearTimeout(timer); resolve(); }
    };
    child.stdout.on("data", ready);
    child.stderr.on("data", ready);
    child.once("exit", (code) => { clearTimeout(timer); reject(new Error(`ingress exited ${code}: ${output}`)); });
  });
  const loopback = await connectTo("127.0.0.1");
  if (loopback) throw new Error(`ingress rejected loopback: ${loopback.message}`);
  const external = Object.values(networkInterfaces()).flat().filter((address) => address.family === "IPv4" && !address.internal).map((address) => address.address);
  if (external.length === 0) throw new Error("container has no non-internal IPv4 address");
  for (const host of external) {
    const result = await connectTo(host);
    if (!result) throw new Error(`ingress accepted non-loopback connection at ${host}`);
  }
} finally {
  if (child.exitCode === null) {
    child.kill("SIGTERM");
    await new Promise((resolve) => child.once("exit", resolve));
  }
}
