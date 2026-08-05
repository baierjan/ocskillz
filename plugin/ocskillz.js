/**
 * ocskillz plugin for opencode.
 *
 * Registers this package's skills, agents, and commands through the `config`
 * hook, so installing the plugin is enough — no symlinking of
 * ~/.config/opencode required.
 *
 * Existing definitions always win: if the merged config already has an agent
 * or command under the same name, we leave it alone.
 */

import fs from "fs"
import path from "path"
import { fileURLToPath } from "url"
import { parse as parseYaml } from "yaml"

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const SKILLS_DIR = path.join(ROOT, "skills")
const AGENTS_DIR = path.join(ROOT, "agents")
const COMMANDS_DIR = path.join(ROOT, "commands")

const FRONTMATTER = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/

/**
 * Split a markdown file into parsed frontmatter and body.
 * Throws if the frontmatter is present but not a YAML mapping.
 */
const parseDocument = (content) => {
  const match = content.match(FRONTMATTER)
  if (!match) return { frontmatter: {}, body: content.trim() }

  const frontmatter = parseYaml(match[1]) ?? {}
  if (typeof frontmatter !== "object" || Array.isArray(frontmatter)) {
    throw new Error("frontmatter is not a mapping")
  }
  return { frontmatter, body: match[2].trim() }
}

const markdownFiles = (dir) => {
  let entries
  try {
    entries = fs.readdirSync(dir)
  } catch {
    return []
  }
  return entries
    .filter((name) => name.endsWith(".md"))
    .sort()
    .map((name) => ({ name: name.slice(0, -3), file: path.join(dir, name) }))
}

export const OcskillzPlugin = async ({ client }) => {
  // Log requests are awaited before the config hook returns; fire-and-forget
  // loses the race against process teardown and the warning disappears.
  const pending = []
  const warn = (message, extra) => {
    try {
      pending.push(
        client.app.log({ body: { service: "ocskillz", level: "warn", message, extra } }),
      )
    } catch {
      // Logging must never break startup.
    }
  }

  /**
   * Read every markdown file in `dir` and hand the parsed result to `build`,
   * which returns the config value to register under `keyOf(doc, basename)`.
   * Files that fail to parse are skipped with a warning so one bad file cannot
   * take the rest of the package down with it.
   */
  const register = (dir, target, keyOf, build) => {
    for (const { name, file } of markdownFiles(dir)) {
      let doc
      try {
        doc = parseDocument(fs.readFileSync(file, "utf8"))
      } catch (error) {
        warn(`skipped ${path.basename(dir)}/${name}.md: ${error.message}`, { file })
        continue
      }

      if (!doc.body) {
        warn(`skipped ${path.basename(dir)}/${name}.md: body is empty`, { file })
        continue
      }

      const key = keyOf(doc, name)
      if (target[key] !== undefined) continue

      target[key] = build(doc)
    }
  }

  return {
    config: async (config) => {
      config.skills = config.skills || {}
      config.skills.paths = config.skills.paths || []
      if (!config.skills.paths.includes(SKILLS_DIR)) {
        config.skills.paths.push(SKILLS_DIR)
      }

      config.agent = config.agent || {}
      register(
        AGENTS_DIR,
        config.agent,
        ({ frontmatter }, basename) =>
          typeof frontmatter.name === "string" ? frontmatter.name : basename,
        ({ frontmatter, body }) => {
          const { name: _name, ...rest } = frontmatter
          return { ...rest, prompt: body }
        },
      )

      // opencode commands take their name from the filename only.
      config.command = config.command || {}
      register(
        COMMANDS_DIR,
        config.command,
        (_doc, basename) => basename,
        ({ frontmatter, body }) => ({ ...frontmatter, template: body }),
      )

      await Promise.allSettled(pending)
    },
  }
}
