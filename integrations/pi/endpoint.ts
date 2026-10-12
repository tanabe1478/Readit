import path from "node:path";

/** Create a per-session local IPC endpoint suitable for the current platform. */
export function sessionEndpoint(
  platform: NodeJS.Platform,
  home: string,
  pid: number,
  suffix: string,
): string {
  if (platform === "win32") return `\\\\.\\pipe\\readit-pi-${pid}-${suffix}`;
  return path.join(home, ".readit/sessions", `pi-${pid}-${suffix}.sock`);
}
