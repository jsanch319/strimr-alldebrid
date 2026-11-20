import { randomBytes, createHash } from "node:crypto";

export interface PairIdentity { userId: string; username: string; instanceId: string }

/** One-use capability, never included in room state, URLs, or logs. */
export class NativePairing {
  private readonly codes = new Map<string, { identity: PairIdentity; expires: number }>();
  constructor(private readonly now = Date.now) {}
  issue(identity: PairIdentity): string {
    for (const [key, item] of this.codes) {
      if (item.expires <= this.now() || (item.identity.instanceId === identity.instanceId && item.identity.userId === identity.userId)) this.codes.delete(key);
    }
    if (this.codes.size >= 1000) throw new Error("Pairing is busy. Retry later.");
    const code = randomBytes(18).toString("base64url");
    this.codes.set(this.hash(code), { identity, expires: this.now() + 120_000 });
    return code;
  }
  redeem(code: unknown): PairIdentity {
    if (typeof code !== "string" || !/^[\w-]{24}$/.test(code)) throw new Error("Invalid or expired pairing code.");
    const key = this.hash(code), item = this.codes.get(key);
    this.codes.delete(key);
    if (!item || item.expires <= this.now()) throw new Error("Invalid or expired pairing code.");
    return item.identity;
  }
  private hash(code: string) { return createHash("sha256").update(code).digest("hex"); }
}
