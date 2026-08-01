// Node identity resolution via the OS-level tailscaled (e.g. on armbian).
//
// The hub must map a connecting socket's tailnet IP back to the node's
// *stable* node id (`n1234abcd`) — the same value the client sends in its
// `hello` frame. The client's `stableNodeId` comes from `tailscale status
// --json` (ipnstate `Peer.ID` / `Self.ID`), so we resolve from that exact
// same source rather than trusting `tailscale whois` text formatting, which
// varies across tailscale versions:
//
//   PRIMARY:  `tailscale status --json` — find the peer whose TailscaleIPs
//             contains the connecting IP, read its `ID` (stable node id).
//   FALLBACK: `tailscale whois <ip>` — parse `StableID`, never the numeric
//             `ID` field (an internal numeric id that never matches a
//             client's stable node id).

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export interface NodeIdentity {
  /** stableNodeId, e.g. `n1234abcd` */
  nodeId: string;
  hostname: string;
  loginName: string;
}

/**
 * Parses `tailscale status --json` and returns the identity of the peer that
 * owns [ip]. In ipnstate JSON a peer's `ID` field is its stable node id —
 * the exact value the Dart client reads as `stableNodeId`.
 */
export function parseStatusJson(
  stdout: string,
  ip: string,
): NodeIdentity | null {
  let parsed: { Peer?: Record<string, unknown> };
  try {
    parsed = JSON.parse(stdout) as { Peer?: Record<string, unknown> };
  } catch {
    return null;
  }
  const peers = parsed.Peer ?? {};
  for (const raw of Object.values(peers)) {
    if (typeof raw !== 'object' || raw === null) continue;
    const peer = raw as Record<string, unknown>;
    const ips = peer.TailscaleIPs;
    if (!Array.isArray(ips) || !ips.includes(ip)) continue;
    const nodeId = peer.ID;
    if (typeof nodeId !== 'string' || nodeId === '') return null;
    const hostname =
      (typeof peer.HostName === 'string' ? peer.HostName : '') ||
      (typeof peer.DNSName === 'string' ? peer.DNSName : '');
    return { nodeId, hostname, loginName: '' };
  }
  return null;
}

/** Parses `tailscale whois` text output into a NodeIdentity. */
export function parseWhoisOutput(stdout: string): NodeIdentity {
  const node: Record<string, string> = {};
  const profile: Record<string, string> = {};
  let section = 'node';

  for (const line of stdout.split('\n')) {
    const trimmed = line.trim();
    if (trimmed.startsWith('#')) {
      section = trimmed.slice(1).trim().replace(':', '');
      continue;
    }
    const idx = trimmed.indexOf(':');
    if (idx < 0) continue;
    const key = trimmed.slice(0, idx).trim();
    const value = trimmed.slice(idx + 1).trim();
    if (section === 'node') node[key] = value;
    else if (section === 'profile') profile[key] = value;
  }

  return {
    nodeId: node.StableID ?? node.ID ?? '',
    hostname: node.Hostname ?? node.Name ?? '',
    loginName: profile.LoginName ?? '',
  };
}

/**
 * Resolves [ip] to its stable node identity, or null on any failure.
 *
 * A freshly registered client may not appear in the hub's `Peer` netmap for a
 * moment, so the status --json path retries briefly before falling back.
 */
export async function runWhois(ip: string): Promise<NodeIdentity | null> {
  // Primary: `tailscale status --json` — same ipnstate data source the client
  // uses for its stableNodeId, so the values are guaranteed to compare equal.
  // Per-call timeout is short: 5 attempts + backoff (~11.2s worst case) must
  // stay under the client's hello-ack window (20s) even if the CLI wedges,
  // while leaving enough room for a freshly registered node to appear in the
  // hub's netmap (the sync race that causes `whois mismatch: not a tailnet
  // node` right after re-registration).
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      const { stdout } = await execFileAsync('tailscale', ['status', '--json'], {
        timeout: 2000,
      });
      const identity = parseStatusJson(stdout, ip);
      if (identity) return identity;
    } catch {
      // transient CLI/tailscaled error — retry
    }
    if (attempt < 4) {
      await new Promise((resolve) => setTimeout(resolve, 300));
    }
  }

  // Fallback: `tailscale whois <ip>` text output. 3s keeps the worst-case
  // total (retries + this ≈ 14.2s) under the client's 20s hello-ack window.
  try {
    const { stdout } = await execFileAsync('tailscale', ['whois', ip], {
      timeout: 3000,
    });
    const identity = parseWhoisOutput(stdout);
    return identity.nodeId ? identity : null;
  } catch {
    return null; // tailscale CLI missing or tailscaled not running
  }
}
