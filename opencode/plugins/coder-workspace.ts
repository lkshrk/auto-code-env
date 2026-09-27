import { readFile } from "node:fs/promises"
import { createHash } from "node:crypto"
import path from "node:path"

type Options = {
  coderUrl?: string
  coderToken?: string
  wildcardHost?: string
  template?: string
  agent?: string
  githubToken?: string
  defaultStacks?: string[]
  localSpawner?: string
  workspaceConfig?: string
  autostopHours?: number
}

type Info = {
  id: string
  type: string
  name: string
  branch?: string | null
  directory?: string | null
  extra?: unknown
  projectID: string
}

type Extra = { repository: string; stacks: string[]; dind: boolean; coderWorkspace: string }

type Spawned = { id: string; repository: string; directory: string; port: number }

const MARKERS: [string, string][] = [
  ["go.mod", "go"],
  ["pyproject.toml", "python"],
  ["requirements.txt", "python"],
  ["package.json", "ts"],
  ["Cargo.toml", "rust"],
  ["kustomization.yaml", "gitops"],
  ["helmfile.yaml", "gitops"],
  ["talos", "talos"],
  ["main.tf", "iac"],
  [".luarc.json", "lua"],
]
const CONTAINER_MARKERS = ["Dockerfile", "compose.yaml", "docker-compose.yml", "docker-compose.yaml"]
const TARGET_TTL_MS = 15_000

function settings(options: Options = {}) {
  const env = process.env
  return {
    coderUrl: (options.coderUrl ?? env.CODER_URL ?? "").replace(/\/$/, ""),
    coderToken: options.coderToken ?? env.CODER_SESSION_TOKEN ?? "",
    wildcardHost: options.wildcardHost ?? env.CODER_WILDCARD_HOST ?? "",
    template: options.template ?? "dev",
    agent: options.agent ?? "main",
    githubToken: options.githubToken ?? env.GITHUB_TOKEN ?? "",
    defaultStacks: options.defaultStacks ?? ["quality"],
    localSpawner: options.localSpawner ?? env.OPENCODE_LOCAL_SPAWNER ?? "",
    workspaceConfig: options.workspaceConfig ?? env.OPENCODE_WORKSPACE_CONFIG ?? "",
    autostopHours: options.autostopHours ?? 4,
  }
}

type Settings = ReturnType<typeof settings>

// Workspace servers get their config from the control plane; {env:NAME} resolves here, not there.
async function workspaceConfig(file: string) {
  if (!file) return undefined
  const text = await readFile(file, "utf8")
  return text.replace(/\{env:([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, name) => JSON.stringify(process.env[name] ?? "").slice(1, -1))
}

async function originUrl(directory: string) {
  const config = await readFile(path.join(directory, ".git", "config"), "utf8").catch(() => "")
  const section = config.split(/^\[/m).find((s) => s.startsWith('remote "origin"]'))
  return section?.match(/^\s*url\s*=\s*(\S+)/m)?.[1]
}

function githubRepo(repository: string) {
  const match = repository.match(/github\.com[/:]([^/]+)\/([^/]+?)(?:\.git)?\/?$/)
  if (!match) throw new Error(`not a GitHub repository: ${repository}`)
  return { owner: match[1], name: match[2], url: `https://github.com/${match[1]}/${match[2]}.git` }
}

async function detect(repository: string, s: Settings) {
  const { owner, name } = githubRepo(repository)
  const headers: Record<string, string> = { Accept: "application/vnd.github+json" }
  if (s.githubToken) headers.Authorization = `Bearer ${s.githubToken}`
  const response = await fetch(`https://api.github.com/repos/${owner}/${name}/contents/`, { headers })
  if (!response.ok) return { stacks: s.defaultStacks, dind: false }
  const files = new Set(((await response.json()) as { name: string }[]).map((entry) => entry.name))
  const stacks = [...new Set(MARKERS.filter(([file]) => files.has(file)).map(([, stack]) => stack))]
  return {
    stacks: stacks.length ? stacks.sort() : s.defaultStacks,
    dind: CONTAINER_MARKERS.some((file) => files.has(file)),
  }
}

function workspaceName(stacks: string[], dind: boolean) {
  const key = [...stacks].sort().join(",") + (dind ? "+docker" : "")
  return `oc-${stacks.slice(0, 2).join("-")}-${createHash("sha256").update(key).digest("hex").slice(0, 6)}`.slice(0, 32)
}

class Coder {
  constructor(private s: Settings) {}

  async api<T>(method: string, route: string, body?: unknown): Promise<T> {
    const response = await fetch(`${this.s.coderUrl}/api/v2${route}`, {
      method,
      headers: { "Coder-Session-Token": this.s.coderToken, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    if (!response.ok) throw new Error(`Coder ${method} ${route}: ${response.status} ${await response.text()}`)
    return (await response.json()) as T
  }

  async workspace(name: string) {
    return this.api<any>("GET", `/users/me/workspace/${name}`).catch(() => undefined)
  }

  async ensure(extra: Extra) {
    let workspace = await this.workspace(extra.coderWorkspace)
    if (!workspace) {
      const templates = await this.api<any[]>("GET", `/templates?q=${encodeURIComponent(`exact_name:${this.s.template}`)}`)
      const template = templates.find((t) => t.name === this.s.template)
      if (!template) throw new Error(`Coder template ${this.s.template} not found`)
      workspace = await this.api<any>("POST", `/users/me/workspaces`, {
        name: extra.coderWorkspace,
        template_id: template.id,
        ttl_ms: this.s.autostopHours * 3_600_000,
        rich_parameter_values: [
          { name: "stacks", value: JSON.stringify(extra.stacks) },
          { name: "enable_dind", value: String(extra.dind) },
          { name: "enable_opencode", value: "true" },
        ],
      })
    } else if (workspace.latest_build.transition !== "start" || workspace.latest_build.job.status === "failed") {
      await this.api("POST", `/workspaces/${workspace.id}/builds`, { transition: "start" })
    }
    const deadline = Date.now() + 20 * 60_000
    while (Date.now() < deadline) {
      workspace = await this.api<any>("GET", `/workspaces/${workspace.id}`)
      const build = workspace.latest_build
      if (build.job.status === "failed") throw new Error(`Coder workspace ${extra.coderWorkspace} failed to build`)
      const agent = build.resources?.flatMap((r: any) => r.agents ?? []).find((a: any) => a.name === this.s.agent)
      const app = agent?.apps?.find((a: any) => a.slug === "opencode")
      if (build.job.status === "succeeded" && agent?.lifecycle_state === "ready" && app?.health === "healthy") {
        return workspace
      }
      await new Promise((resolve) => setTimeout(resolve, 5_000))
    }
    throw new Error(`Coder workspace ${extra.coderWorkspace} did not become ready`)
  }

  url(workspace: any, port: number | string) {
    const host = `${port}--${this.s.agent}--${workspace.name}--${workspace.owner_name}.${this.s.wildcardHost}`
    return `https://${host}`
  }
}

export default async function CoderWorkspacePlugin(input: any, options?: Options) {
  const s = settings(options)
  const coder = new Coder(s)
  const targets = new Map<string, { at: number; target: { type: "remote"; url: string; headers?: Record<string, string> } }>()

  async function spawner(extra: Extra) {
    if (s.localSpawner) return { base: s.localSpawner, portUrl: (port: number) => `http://127.0.0.1:${port}` }
    const workspace = await coder.ensure(extra)
    return {
      base: coder.url(workspace, "opencode"),
      portUrl: (port: number) => coder.url(workspace, port),
    }
  }

  async function call<T>(base: string, method: string, route: string, body?: unknown): Promise<T> {
    const headers: Record<string, string> = { "Content-Type": "application/json" }
    if (!s.localSpawner) headers["Coder-Session-Token"] = s.coderToken
    const response = await fetch(`${base}${route}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    if (!response.ok) throw new Error(`spawner ${method} ${route}: ${response.status} ${await response.text()}`)
    return (await response.json()) as T
  }

  const extraOf = (info: Info) => info.extra as Extra

  input.experimental_workspace.register("coder", {
    name: "Coder",
    description: "Git worktree in a Coder workspace chosen by the repository's stacks",
    async configure(info: Info) {
      const given = (info.extra ?? {}) as Partial<Extra>
      const repository = githubRepo(given.repository ?? (await originUrl(input.worktree ?? input.directory)) ?? "").url
      const detected = given.stacks ? { stacks: given.stacks, dind: !!given.dind } : await detect(repository, s)
      const extra: Extra = { repository, ...detected, coderWorkspace: workspaceName(detected.stacks, detected.dind) }
      const name = githubRepo(repository).name
      return { ...info, name: `${name}-${info.id.slice(-6)}`, directory: `~/src/${name}/.worktrees/${info.id}`, extra }
    },
    async create(info: Info, env: Record<string, string | undefined>) {
      const extra = extraOf(info)
      const { base } = await spawner(extra)
      const forwarded: Record<string, string> = Object.fromEntries(
        Object.entries(env).filter((entry): entry is [string, string] => entry[1] !== undefined),
      )
      const config = await workspaceConfig(s.workspaceConfig)
      if (config) forwarded.OPENCODE_CONFIG_CONTENT = config
      await call<Spawned>(base, "POST", "/workspaces", {
        id: info.id,
        repository: extra.repository,
        ...(info.branch ? { branch: info.branch } : {}),
        env: forwarded,
      })
    },
    async remove(info: Info) {
      const { base } = await spawner(extraOf(info))
      await call(base, "DELETE", `/workspaces/${info.id}`).catch(() => undefined)
      targets.delete(info.id)
    },
    async target(info: Info) {
      const cached = targets.get(info.id)
      if (cached && Date.now() - cached.at < TARGET_TTL_MS) return cached.target
      const { base, portUrl } = await spawner(extraOf(info))
      const spawned = await call<Spawned>(base, "GET", `/workspaces/${info.id}`)
      const target = {
        type: "remote" as const,
        url: portUrl(spawned.port),
        ...(s.localSpawner ? {} : { headers: { "Coder-Session-Token": s.coderToken } }),
      }
      targets.set(info.id, { at: Date.now(), target })
      return target
    },
  })

  return {}
}
