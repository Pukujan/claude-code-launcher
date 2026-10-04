#!/usr/bin/env node
// Runs Claude Code with the claude-code-launcher environment, for tools that
// start `claude` themselves and pass their own arguments (Paseo, scripts).
//
//   node shared/integrations/claude-env-exec.mjs [claude arguments...]
//
// It asks the launcher for its variables in non-interactive mode
// (`--non-interactive --print-env json`, which never starts, restarts or
// reloads the proxy and never prompts), applies them to a copy of this
// process's environment, then runs claude with the arguments exactly as given.
// Node passes them straight to the process, so JSON arguments keep their quotes
// (Windows PowerShell 5.1 would drop them).
//
// Settings (all optional):
//   CCL_CLAUDE_BIN    the claude executable (default: claude.exe or the target of
//                     the npm claude.cmd shim on Windows, `claude` elsewhere)
//   CCL_ENV_COMMAND   a JSON array that prints the env JSON (default: this
//                     repository's launcher for this OS)
//
// Names under CLAUDE_CODE_ are cleared only when the launcher lists them by
// name. The prefix sweep would otherwise remove the control variables an SDK
// host sets for claude (CLAUDE_CODE_ENTRYPOINT, file checkpointing and so on).
import { spawn, execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..", "..");
const isWindows = process.platform === "win32";
const KEEP_PREFIXES = ["CLAUDE_CODE_"];

function fail(message, code = 1) {
  process.stderr.write(`claude-env-exec: ${message}\n`);
  process.exit(code);
}

export function launcherCommand(env = process.env) {
  if (env.CCL_ENV_COMMAND) {
    const argv = JSON.parse(env.CCL_ENV_COMMAND);
    if (!Array.isArray(argv) || argv.length === 0) throw new Error("CCL_ENV_COMMAND must be a JSON array");
    return argv;
  }
  if (isWindows) {
    return ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
      path.join(repo, "windows", "launch-claude-inferhub.ps1"), "--non-interactive", "--print-env", "json"];
  }
  return ["bash", path.join(repo, "mac", "Launch Claude InferHub.command"), "--non-interactive", "--print-env", "json"];
}

export function applyPlan(baseEnv, plan) {
  // Returns a new env: the launcher's unset names and prefixes removed (names
  // compared case-insensitively on Windows), then its values set.
  const exact = new Set((plan.unset ?? []).map((n) => (isWindows ? n.toUpperCase() : n)));
  const prefixes = (plan.unset_prefixes ?? []).filter((p) => !KEEP_PREFIXES.includes(p));
  const out = {};
  for (const [name, value] of Object.entries(baseEnv)) {
    const key = isWindows ? name.toUpperCase() : name;
    if (exact.has(key)) continue;
    if (prefixes.some((p) => (isWindows ? key.startsWith(p.toUpperCase()) : name.startsWith(p)))) continue;
    out[name] = value;
  }
  for (const [name, value] of Object.entries(plan.set ?? {})) {
    for (const existing of Object.keys(out)) {
      if (isWindows && existing.toUpperCase() === name.toUpperCase()) delete out[existing];
    }
    out[name] = String(value);
  }
  return out;
}

function findOnPath(names, env) {
  const dirs = (env.PATH ?? env.Path ?? "").split(path.delimiter).filter(Boolean);
  for (const dir of dirs) {
    for (const name of names) {
      const p = path.join(dir, name);
      if (existsSync(p)) return p;
    }
  }
  return null;
}

export function resolveClaude(env = process.env) {
  if (env.CCL_CLAUDE_BIN) return env.CCL_CLAUDE_BIN;
  if (!isWindows) return findOnPath(["claude"], env) ?? "claude";
  const exe = findOnPath(["claude.exe"], env);
  if (exe) return exe;
  // npm's claude.cmd shim names the real executable: "%dp0%\node_modules\...\claude.exe".
  const cmd = findOnPath(["claude.cmd"], env);
  if (cmd) {
    const m = readFileSync(cmd, "utf8").match(/"%dp0%\\([^"]+\.exe)"/i);
    if (m) {
      const target = path.join(path.dirname(cmd), m[1]);
      if (existsSync(target)) return target;
    }
  }
  return null;
}

function readPlan() {
  const [cmd, ...args] = launcherCommand();
  let stdout;
  try {
    stdout = execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"], windowsHide: true, timeout: 60_000 });
  } catch (error) {
    fail(`the launcher did not hand over its environment (exit ${error.status ?? "?"})`, error.status === 3 ? 3 : 1);
  }
  const line = stdout.trim().split(/\r?\n/).filter((l) => l.startsWith("{")).pop();
  if (!line) fail("the launcher printed no JSON");
  return JSON.parse(line);
}

function main() {
  const args = process.argv.slice(2);
  // Version and auth probes need no proxy and must be quick (Paseo gives them 5 s).
  const probe = args.length > 0 && (args[0] === "--version" || args[0] === "-v" || args[0] === "auth");
  const env = probe ? { ...process.env } : applyPlan(process.env, readPlan());
  const claude = resolveClaude(env);
  if (!claude) fail("claude was not found on PATH; set CCL_CLAUDE_BIN");
  const child = spawn(claude, args, { stdio: "inherit", env, windowsHide: true });
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => { try { child.kill(sig); } catch { /* already gone */ } });
  }
  child.on("error", (error) => fail(`could not start ${claude}: ${error.message}`));
  child.on("exit", (code, signal) => process.exit(code ?? (signal ? 1 : 0)));
}

const self = fileURLToPath(import.meta.url);
const invoked = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (isWindows ? invoked.toLowerCase() === self.toLowerCase() : invoked === self) main();
