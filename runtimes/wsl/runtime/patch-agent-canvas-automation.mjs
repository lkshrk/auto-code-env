import { readFileSync, writeFileSync } from "node:fs";

const path = process.argv[2];
if (!path) throw new Error("usage: patch-agent-canvas-automation.mjs <dev-with-automation.mjs|ingress.mjs>");

// Temporary workaround for OpenHands/OpenHands#16217. Remove this patch when #16635 ships in Agent Canvas.
const automationReplacements = [
  [
    `  const uvxArgs = [];
  let source = "";

`,
    ""
  ],
  [
    `    uvxArgs.push(
      "--refresh",
      "--from",
      gitUrl,
      "uvicorn",
      "openhands.automation.app:app",
    );
    source = \`git (${"${gitRef}"})\`;
`,
    `    return {
      command: "uv",
      args: [
        "run",
        "--no-project",
        "--refresh",
        "--with",
        gitUrl,
        "python",
        "-m",
        "uvicorn",
        "openhands.automation.app:app",
      ],
      source: \`git (${"${gitRef}"})\`,
    };
`
  ],
  [
    `  } else if (version) {
    // Use specific PyPI version
    uvxArgs.push(
      "--from",
      \`${"${DEFAULT_AUTOMATION_PACKAGE}"}==${"${version}"}\`,
      "uvicorn",
      "openhands.automation.app:app",
    );
    source = \`PyPI (${"${version}"})\`;
`,
    `  } else if (version) {
    // Use specific PyPI version
    return {
      command: "uv",
      args: [
        "run",
        "--no-project",
        "--with",
        \`${"${DEFAULT_AUTOMATION_PACKAGE}"}==${"${version}"}\`,
        "python",
        "-m",
        "uvicorn",
        "openhands.automation.app:app",
      ],
      source: \`PyPI (${"${version}"})\`,
    };
`
  ],
  [
    `  } else {
    // Default to released PyPI version
    uvxArgs.push(
      "--from",
      \`${"${DEFAULT_AUTOMATION_PACKAGE}"}==${"${DEFAULT_AUTOMATION_VERSION}"}\`,
      "uvicorn",
      "openhands.automation.app:app",
    );
    source = \`PyPI (${"${DEFAULT_AUTOMATION_VERSION}"}, default)\`;
`,
    `  } else {
    // Default to released PyPI version
    return {
      command: "uv",
      args: [
        "run",
        "--no-project",
        "--with",
        \`${"${DEFAULT_AUTOMATION_PACKAGE}"}==${"${DEFAULT_AUTOMATION_VERSION}"}\`,
        "python",
        "-m",
        "uvicorn",
        "openhands.automation.app:app",
      ],
      source: \`PyPI (${"${DEFAULT_AUTOMATION_VERSION}"}, default)\`,
    };
`
  ],
  [
    `
  return {
    command: "uvx",
    args: uvxArgs,
    source,
  };
`,
    "\n"
  ]
];

let source = readFileSync(path, "utf8");
// Keep Canvas ingress private; nginx is the only LAN-facing listener.
const replacements = path.endsWith("/ingress.mjs") || path.endsWith("\\ingress.mjs")
  ? [[`  server.listen(config.port, () => {`, `  server.listen(config.port, "127.0.0.1", () => {`]]
  : automationReplacements;
for (const [index, [before, after]] of replacements.entries()) {
  const count = source.split(before).length - 1;
  if (count !== 1) throw new Error(`expected one unpatched Agent Canvas snippet ${index}, found ${count}`);
  source = source.replace(before, after);
}
writeFileSync(path, source);
