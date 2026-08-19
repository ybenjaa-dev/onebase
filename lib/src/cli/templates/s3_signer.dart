/// AWS Signature Version 4 presigner, written out into the generated backend.
///
/// Presigned URLs are why the backend stays tiny: file bytes go straight from
/// the device to your object store, so the server only ever signs a short-lived
/// URL. Implemented directly on `node:crypto` rather than pulling in the AWS
/// SDK, which would be larger than the rest of the backend put together.
///
/// Works with anything S3-compatible: AWS S3, Cloudflare R2, MinIO, Backblaze
/// B2, DigitalOcean Spaces.
const s3SignerTs = r'''
import { createHash, createHmac } from 'node:crypto';

export interface S3Config {
  endpoint?: string;
  region: string;
  bucket: string;
  accessKeyId: string;
  secretAccessKey: string;
  forcePathStyle: boolean;
}

export interface PresignInput {
  config: S3Config;
  method: 'GET' | 'PUT' | 'DELETE';
  /** Object key, without a leading slash. */
  key: string;
  expiresIn: number;
  /** Headers the caller must send exactly; they become part of the signature. */
  headers?: Record<string, string>;
  /** Fixed clock, for tests. */
  now?: Date;
}

const ALGORITHM = 'AWS4-HMAC-SHA256';
const SERVICE = 's3';

function sha256Hex(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

function hmac(key: Buffer | string, value: string): Buffer {
  return createHmac('sha256', key).update(value, 'utf8').digest();
}

/**
 * RFC 3986 encoding. `encodeURIComponent` leaves `!'()*` alone, which AWS
 * expects to be escaped — a mismatch produces a signature that verifies
 * locally and is rejected by S3.
 */
function uriEncode(value: string): string {
  return encodeURIComponent(value).replace(
    /[!'()*]/g,
    (char) => `%${char.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

/** Each path segment is encoded, but the separators are not. */
function encodeKey(key: string): string {
  return key.split('/').map(uriEncode).join('/');
}

/** Resolves the host and path prefix for the configured provider. */
export function resolveEndpoint(config: S3Config): {
  origin: string;
  host: string;
  basePath: string;
} {
  if (config.endpoint) {
    const url = new URL(config.endpoint);
    const basePath = config.forcePathStyle ? `/${config.bucket}` : '';
    return { origin: url.origin, host: url.host, basePath };
  }
  // Plain AWS: virtual-hosted style.
  const host = `${config.bucket}.s3.${config.region}.amazonaws.com`;
  return { origin: `https://${host}`, host, basePath: '' };
}

/**
 * Builds a presigned URL. The returned URL carries the signature in its query
 * string, so the client needs no credentials — only this URL, and whatever
 * headers were signed alongside it.
 */
export function presign(input: PresignInput): string {
  const { config, method, key, expiresIn } = input;
  const now = input.now ?? new Date();

  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/${config.region}/${SERVICE}/aws4_request`;

  const { origin, host, basePath } = resolveEndpoint(config);
  const canonicalUri = `${basePath}/${encodeKey(key)}`;

  const headers: Record<string, string> = { host, ...(input.headers ?? {}) };
  const canonicalHeaderNames = Object.keys(headers)
    .map((name) => name.toLowerCase())
    .sort();
  const canonicalHeaders = canonicalHeaderNames
    .map((name) => {
      const value = Object.entries(headers).find(
        ([key]) => key.toLowerCase() === name,
      )![1];
      return `${name}:${String(value).trim().replace(/\s+/g, ' ')}\n`;
    })
    .join('');
  const signedHeaders = canonicalHeaderNames.join(';');

  const query: Record<string, string> = {
    'X-Amz-Algorithm': ALGORITHM,
    'X-Amz-Credential': `${config.accessKeyId}/${scope}`,
    'X-Amz-Date': amzDate,
    'X-Amz-Expires': String(expiresIn),
    'X-Amz-SignedHeaders': signedHeaders,
  };
  const canonicalQuery = Object.keys(query)
    .sort()
    .map((name) => `${uriEncode(name)}=${uriEncode(query[name])}`)
    .join('&');

  const canonicalRequest = [
    method,
    canonicalUri,
    canonicalQuery,
    canonicalHeaders,
    signedHeaders,
    'UNSIGNED-PAYLOAD',
  ].join('\n');

  const stringToSign = [
    ALGORITHM,
    amzDate,
    scope,
    sha256Hex(canonicalRequest),
  ].join('\n');

  const signingKey = hmac(
    hmac(hmac(hmac(`AWS4${config.secretAccessKey}`, dateStamp), config.region), SERVICE),
    'aws4_request',
  );
  const signature = createHmac('sha256', signingKey)
    .update(stringToSign, 'utf8')
    .digest('hex');

  return `${origin}${canonicalUri}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}
''';
