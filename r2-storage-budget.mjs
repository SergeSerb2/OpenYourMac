#!/usr/bin/env node
import * as NodeCrypto from "node:crypto";
import * as NodeChildProcess from "node:child_process";
import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

const { createHash, createHmac, randomUUID } = NodeCrypto;
const { spawn } = NodeChildProcess;
const { stat, readFile } = NodeFSP;
const { homedir } = NodeOS;
const path = NodePath;
const { fileURLToPath } = NodeURL;

const ACCOUNT = "a6f705b8c6459d937d32d31555f9fbf6";
const ENDPOINT = `https://${ACCOUNT}.r2.cloudflarestorage.com`;
const LOCK_BUCKET = "t3-pretty-releases";
const LOCK_KEY = "__r2_budget__/account-write-lock.json";
const requestedLimit = Number(process.env.R2_BUDGET_MAX_BYTES ?? 9_000_000_000);
if (
  !Number.isSafeInteger(requestedLimit) ||
  requestedLimit <= 0 ||
  requestedLimit > 9_000_000_000
) {
  throw new Error("R2_BUDGET_MAX_BYTES may lower the 9 GB ceiling, but cannot raise it.");
}
const LIMIT = requestedLimit;
const TARGET = 8_000_000_000;
const OBJECT_OVERHEAD = 8192;
const RELEASE_BUCKETS = new Set([
  LOCK_BUCKET,
  "opencast-releases",
  "opencove-releases",
  "openergy-releases",
  "opentodos-updates",
  "openyourmac-releases",
]);
const NIGHTLY = /\d+\.\d+\.\d+-nightly\.\d{8}\.\d+/;
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const hmac = (key, value) => createHmac("sha256", key).update(value).digest();
const encode = (value) =>
  encodeURIComponent(value).replace(
    /[!'()*]/g,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`,
  );
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const xml = (text) =>
  text.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos);/gi, (_, entity) => {
    if (entity.startsWith("#x")) return String.fromCodePoint(parseInt(entity.slice(2), 16));
    if (entity.startsWith("#")) return String.fromCodePoint(Number(entity.slice(1)));
    return { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" }[entity.toLowerCase()];
  });
const tag = (text, name) =>
  xml(text.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`))?.[1] ?? "");
const blocks = (text, name) =>
  [...text.matchAll(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`, "g"))].map((m) => m[1]);

async function boundedText(response, limit = 4 * 1024 * 1024) {
  const chunks = [];
  let length = 0;
  for await (const chunk of response.body ?? []) {
    length += chunk.length;
    if (length > limit) throw new Error("R2 budget response exceeded its size limit.");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function credentials(fallback) {
  const access = process.env.R2_BUDGET_ACCESS_KEY_ID;
  const secret = process.env.R2_BUDGET_SECRET_ACCESS_KEY;
  if (Boolean(access) !== Boolean(secret)) throw new Error("Set both R2 budget credentials.");
  if (access) return { access, secret };
  if (process.env.CLOUDFLARE_API_TOKEN) {
    for (const route of [`/accounts/${ACCOUNT}/tokens/verify`, "/user/tokens/verify"]) {
      const response = await fetch(`https://api.cloudflare.com/client/v4${route}`, {
        headers: { authorization: `Bearer ${process.env.CLOUDFLARE_API_TOKEN}` },
        redirect: "error",
        signal: AbortSignal.timeout(30_000),
      });
      const data = JSON.parse(await boundedText(response));
      if (response.ok && data.success && data.result.status === "active") {
        return { access: data.result.id, secret: sha256(process.env.CLOUDFLARE_API_TOKEN) };
      }
    }
    throw new Error("R2 budget could not verify the configured Cloudflare token.");
  }
  try {
    const saved = JSON.parse(
      await readFile(path.join(homedir(), ".config/r2-budget/credentials.json"), "utf8"),
    );
    if (saved.access && saved.secret) return saved;
  } catch (error) {
    // eslint-disable-next-line preserve-caught-error -- Credential errors can contain private paths.
    if (error.code !== "ENOENT") throw new Error("R2 budget credential file could not be read.");
  }
  if (fallback?.access && fallback?.secret) return fallback;
  const pairs = [
    ["T3CODE_RELEASE_S3_ACCESS_KEY_ID", "T3CODE_RELEASE_S3_SECRET_ACCESS_KEY"],
    ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"],
  ];
  for (const [a, s] of pairs) {
    if (process.env[a] && process.env[s]) return { access: process.env[a], secret: process.env[s] };
  }
  throw new Error("R2 budget requires account-wide R2 read/write credentials. Upload was blocked.");
}

async function client(fallback) {
  const auth = await credentials(fallback);
  return async (method, bucket = "", key = "", payload, extraHeaders = {}, parameters = {}) => {
    const uri = "/" + [bucket, ...key.split("/")].filter(Boolean).map(encode).join("/");
    const query = Object.entries(parameters)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([k, v]) => `${encode(k)}=${encode(String(v))}`)
      .join("&");
    const now = new Date().toISOString().replace(/[:-]|\.\d{3}/g, "");
    const date = now.slice(0, 8);
    const digest = sha256(payload ?? "");
    const headers = {
      ...extraHeaders,
      host: new URL(ENDPOINT).host,
      "accept-encoding": "identity",
      "x-amz-date": now,
      "x-amz-content-sha256": digest,
    };
    const names = Object.keys(headers).sort();
    const canonical = [
      method,
      uri,
      query,
      names.map((n) => `${n}:${String(headers[n]).trim()}\n`).join(""),
      names.join(";"),
      digest,
    ].join("\n");
    const scope = `${date}/auto/s3/aws4_request`;
    const signing = hmac(
      hmac(hmac(hmac(`AWS4${auth.secret}`, date), "auto"), "s3"),
      "aws4_request",
    );
    const signature = createHmac("sha256", signing)
      .update(`AWS4-HMAC-SHA256\n${now}\n${scope}\n${sha256(canonical)}`)
      .digest("hex");
    headers.authorization = `AWS4-HMAC-SHA256 Credential=${auth.access}/${scope}, SignedHeaders=${names.join(";")}, Signature=${signature}`;
    try {
      return await fetch(ENDPOINT + uri + (query ? "?" + query : ""), {
        method,
        headers,
        ...(payload === undefined ? {} : { body: payload }),
        redirect: "error",
        signal: AbortSignal.timeout(120_000),
      });
    } catch {
      throw new Error("R2 budget request failed; upload is blocked until storage state is known.");
    }
  };
}

async function inventory(s3) {
  const response = await s3("GET");
  if (!response.ok)
    throw new Error(
      `R2 budget cannot list all account buckets (HTTP ${response.status}). Upload blocked.`,
    );
  const names = blocks(await boundedText(response), "Bucket").map((b) => tag(b, "Name"));
  if (!names.includes(LOCK_BUCKET)) throw new Error("R2 budget control bucket is missing.");
  const objects = [];
  for (const bucket of names) {
    let continuation;
    do {
      const params = { "list-type": 2, "max-keys": 1000 };
      if (continuation) params["continuation-token"] = continuation;
      const page = await s3("GET", bucket, "", undefined, {}, params);
      if (!page.ok)
        throw new Error(
          `R2 budget cannot inventory a bucket (HTTP ${page.status}). Upload blocked.`,
        );
      const text = await boundedText(page);
      for (const item of blocks(text, "Contents")) {
        const size = Number(tag(item, "Size"));
        const modified = Date.parse(tag(item, "LastModified"));
        if (!Number.isSafeInteger(size) || size < 0 || !Number.isFinite(modified))
          throw new Error("R2 inventory contains invalid metadata.");
        objects.push({
          bucket,
          key: tag(item, "Key"),
          bytes: size,
          modified,
          etag: tag(item, "ETag"),
        });
      }
      continuation = tag(text, "IsTruncated") === "true" ? tag(text, "NextContinuationToken") : "";
      if (tag(text, "IsTruncated") === "true" && !continuation)
        throw new Error("R2 inventory pagination is incomplete.");
    } while (continuation);
    const multipart = await s3("GET", bucket, "", undefined, {}, { uploads: "" });
    if (!multipart.ok)
      throw new Error(`R2 budget cannot inspect unfinished uploads (HTTP ${multipart.status}).`);
    if (blocks(await boundedText(multipart), "Upload").length) {
      throw new Error(
        "Unfinished R2 multipart uploads exist. Upload blocked until they are completed or aborted.",
      );
    }
  }
  return objects;
}

function group(object) {
  if (object.bucket === LOCK_BUCKET) {
    const version = object.key.startsWith("t3-pretty/latest/") && object.key.match(NIGHTLY)?.[0];
    if (version) return `${object.bucket}:desktop:${version}`;
    if (object.key.startsWith("openspr/releases/"))
      return object.bucket + ":" + object.key.split("/").slice(0, 4).join("/");
    if (
      object.key.startsWith("t3-pretty/mobile-updates/") &&
      !object.key.endsWith("/manifest.json")
    )
      return object.bucket + ":" + object.key;
    if (object.key.startsWith("openspr/history/")) return object.bucket + ":" + object.key;
    return null;
  }
  if (!RELEASE_BUCKETS.has(object.bucket)) return null;
  if (/^releases\//.test(object.key))
    return object.bucket + ":" + object.key.split("/").slice(0, -1).join("/");
  if (/^v\d+\./.test(object.key)) return object.bucket + ":" + object.key.split("/")[0];
  return null;
}

function isCurrentMetadata(object) {
  const key = object.key;
  return (
    key.endsWith("/manifest.json") ||
    key === "release.json" ||
    (key.endsWith("appcast.xml") && !key.includes("/history/")) ||
    (key.startsWith("t3-pretty/latest/") && /(?:latest|nightly)(?:-mac|-linux)?\.yml$/.test(key))
  );
}

function strings(value) {
  if (typeof value === "string") return [value];
  if (Array.isArray(value)) return value.flatMap(strings);
  if (value && typeof value === "object") return Object.values(value).flatMap(strings);
  return [];
}

async function protectedObjects(s3, objects, incoming) {
  const identities = new Map(objects.map((o) => [`${o.bucket}/${o.key}`, o]));
  const protectedKeys = new Set();
  const protect = (o) => protectedKeys.add(`${o.bucket}/${o.key}`);
  for (const object of objects) {
    if (
      !group(object) ||
      object.modified > Date.now() - 30 * 60_000 ||
      (object.bucket === incoming.bucket && object.key === incoming.key)
    )
      protect(object);
    if (!isCurrentMetadata(object)) continue;
    protect(object);
    if (object.bytes > 2 * 1024 * 1024)
      throw new Error("Current update metadata is too large for safe retention.");
    const response = await s3("GET", object.bucket, object.key, undefined, {
      "if-match": object.etag,
    });
    if (!response.ok)
      throw new Error("Current update metadata changed or could not be read. Upload blocked.");
    const text = await boundedText(response, 2 * 1024 * 1024);
    const references = object.key.endsWith(".json")
      ? strings(JSON.parse(text))
      : [
          ...[...text.matchAll(/https?:\/\/[^\s<>"']+/g)].map((m) => xml(m[0])),
          ...[...text.matchAll(/^\s*(?:-\s*)?(?:url|path):\s*["']?([^\s"']+)/gm)].map((m) => m[1]),
        ];
    for (const ref of references) {
      if (ref.length > 4096 || ref.includes("\n")) continue;
      let target;
      try {
        target = new URL(ref, `https://r2-budget.invalid/${object.key}`).pathname;
      } catch {
        continue;
      }
      target = decodeURIComponent(target).replace(/^\//, "");
      const match = identities.get(`${object.bucket}/${target}`);
      if (!match) {
        if (ref.startsWith("https://") && /\.r2\.dev\/|updates\.sergeserbinenko\.com\//.test(ref)) {
          throw new Error("A current update feed references a missing object. Upload blocked.");
        }
        continue;
      }
      protect(match);
      for (const suffix of [".blockmap", ".sha256"]) {
        const sidecar = identities.get(`${object.bucket}/${target}${suffix}`);
        if (sidecar) protect(sidecar);
      }
    }
  }
  const groups = new Set(
    objects
      .filter((o) => protectedKeys.has(`${o.bucket}/${o.key}`))
      .map(group)
      .filter(Boolean),
  );
  const incomingGroup = group(incoming);
  if (incomingGroup) groups.add(incomingGroup);
  for (const object of objects) if (groups.has(group(object))) protect(object);
  return protectedKeys;
}

async function acquire(s3, incoming) {
  const owner = randomUUID();
  const body = JSON.stringify({
    owner,
    createdAt: new Date().toISOString(),
    bucket: incoming.bucket,
    key: incoming.key,
    bytes: incoming.bytes,
  });
  const deadline = Date.now() + 10 * 60_000;
  let announced = false;
  for (;;) {
    const response = await s3("PUT", LOCK_BUCKET, LOCK_KEY, body, {
      "if-none-match": "*",
      "content-type": "application/json",
      "cache-control": "no-store",
    });
    if (response.ok) {
      const etag = response.headers.get("etag");
      await response.body?.cancel();
      if (!etag) throw new Error("R2 budget lock has no ETag. Stop and inspect the lock.");
      return { owner, etag };
    }
    await response.body?.cancel();
    if (response.status !== 412 && response.status !== 409)
      throw new Error(`R2 budget lock failed (HTTP ${response.status}). Upload blocked.`);
    if (Date.now() >= deadline)
      throw new Error(
        "R2 budget lock is still held. Upload blocked; inspect the existing lock before recovery.",
      );
    if (!announced) {
      console.error("Waiting for the account R2 upload lock.");
      announced = true;
    }
    await sleep(1000 + Math.floor(Math.random() * 500));
  }
}

async function release(s3, lock) {
  const response = await s3("DELETE", LOCK_BUCKET, LOCK_KEY, undefined, { "if-match": lock.etag });
  if (!response.ok)
    throw new Error("R2 budget lock could not be released safely. Later uploads remain blocked.");
  await response.body?.cancel();
}

export async function withR2Budget(incoming, upload) {
  if (
    !RELEASE_BUCKETS.has(incoming.bucket) ||
    !incoming.key ||
    incoming.key.startsWith("__r2_budget__/")
  ) {
    throw new Error("R2 budget received an unsupported release destination.");
  }
  if (
    !Number.isSafeInteger(incoming.bytes) ||
    incoming.bytes < 0 ||
    incoming.bytes + OBJECT_OVERHEAD > LIMIT
  ) {
    throw new Error("The release file exceeds the account R2 storage budget. Upload blocked.");
  }
  const s3 = await client(incoming.credentials);
  const lock = await acquire(s3, incoming);
  let started = false;
  let complete = false;
  try {
    let objects = await inventory(s3);
    let used = objects.reduce((n, o) => n + o.bytes + OBJECT_OVERHEAD, 0);
    const required = incoming.bytes + OBJECT_OVERHEAD;
    const protectedKeys = await protectedObjects(s3, objects, incoming);
    if (used + required > LIMIT) {
      const target = Math.min(TARGET, LIMIT - required);
      const groups = new Map();
      for (const object of objects) {
        const id = group(object);
        if (id) groups.set(id, [...(groups.get(id) ?? []), object]);
      }
      const candidates = [...groups.values()]
        .filter((rows) => rows.every((o) => !protectedKeys.has(`${o.bucket}/${o.key}`)))
        .sort(
          (a, b) => Math.max(...a.map((o) => o.modified)) - Math.max(...b.map((o) => o.modified)),
        );
      const chosen = [];
      let projected = used;
      for (const rows of candidates) {
        if (projected <= target) break;
        chosen.push(...rows);
        projected -= rows.reduce((n, o) => n + o.bytes + OBJECT_OVERHEAD, 0);
      }
      if (projected + required > LIMIT)
        throw new Error(
          "Current releases use too much space; no safe oldest-first cleanup can fit this upload.",
        );
      for (const object of chosen) {
        const response = await s3("DELETE", object.bucket, object.key, undefined, {
          "if-match": object.etag,
        });
        if (!response.ok)
          throw new Error(`Old release deletion failed (HTTP ${response.status}). Upload blocked.`);
        await response.body?.cancel();
      }
      objects = await inventory(s3);
      used = objects.reduce((n, o) => n + o.bytes + OBJECT_OVERHEAD, 0);
      console.error(
        JSON.stringify({
          r2Budget: "pruned-oldest-releases",
          deletedObjects: chosen.length,
          usedBytesIncludingOverhead: used,
        }),
      );
    }
    if (used + required > LIMIT)
      throw new Error("Account storage changed during cleanup. Upload blocked.");
    started = true;
    const result = await upload();
    if (result instanceof Response && !result.ok) {
      if (result.status >= 400 && result.status < 500 && result.status !== 408) {
        complete = true;
        return result;
      }
      throw new Error("R2 upload did not return a definite successful result.");
    }
    const head = await s3("HEAD", incoming.bucket, incoming.key);
    if (!head.ok || Number(head.headers.get("content-length")) !== incoming.bytes)
      throw new Error("Uploaded file size could not be verified.");
    complete = true;
    console.error(
      JSON.stringify({
        r2Budget: "upload-verified",
        reservedBytes: required,
        upperBoundBytes: used + required,
        limitBytes: LIMIT,
      }),
    );
    return result;
  } catch (error) {
    const status = error?.$metadata?.httpStatusCode;
    if (status >= 400 && status < 500 && status !== 408) complete = true;
    throw error;
  } finally {
    // A lost upload response is ambiguous. Never expire this lock while a write
    // might still finish; a maintainer must inspect unfinished uploads first.
    if (!started || complete) await release(s3, lock);
    else
      console.error(
        "R2 upload outcome is uncertain. The account upload lock remains held; automatic uploads are blocked.",
      );
  }
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  if (command !== "exec")
    throw new Error(
      "Usage: node r2-storage-budget.mjs exec <bucket> <key> <file> -- <upload-command> [arguments]",
    );
  const [bucket, key, file, separator, executable, ...childArgs] = args;
  if (separator !== "--" || !executable) throw new Error("An upload command after -- is required.");
  const info = await stat(file);
  if (!info.isFile()) throw new Error("Upload source must be a regular file.");
  await withR2Budget(
    { bucket, key, bytes: info.size },
    () =>
      new Promise((resolve, reject) => {
        const child = spawn(executable, childArgs, { stdio: "inherit", env: process.env });
        child.once("error", () => reject(new Error("Upload command could not be started.")));
        child.once("exit", (code, signal) =>
          code === 0 && !signal ? resolve() : reject(new Error("Upload command failed.")),
        );
      }),
  );
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : "R2 budget failed.");
    process.exitCode = 1;
  });
}
