// Verifies the generated SigV4 presigner against AWS's own worked example.
// If this passes, the URLs the backend mints are byte-identical to what the
// AWS SDK would produce — which is the only way to be sure without a real
// bucket to try them against.
import assert from 'node:assert/strict';
import { presign, resolveEndpoint } from '../../example/backend/src/s3.js';

let pass = 0;
const t = (name: string, fn: () => void) => {
  try { fn(); pass++; console.log('  ok  ' + name); }
  catch (e) { console.log('  FAIL ' + name + ' → ' + e); process.exitCode = 1; }
};

t('matches the AWS SigV4 presigned-URL worked example', () => {
  // https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
  const url = presign({
    config: {
      endpoint: 'https://examplebucket.s3.amazonaws.com',
      region: 'us-east-1',
      bucket: 'examplebucket',
      accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
      secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
      forcePathStyle: false,
    },
    method: 'GET',
    key: 'test.txt',
    expiresIn: 86400,
    now: new Date(Date.UTC(2013, 4, 24, 0, 0, 0)),
  });
  assert.equal(
    new URL(url).searchParams.get('X-Amz-Signature'),
    'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404',
  );
});

t('addresses AWS virtual-host style and everything else path style', () => {
  const aws = resolveEndpoint({
    region: 'eu-west-1', bucket: 'b',
    accessKeyId: '', secretAccessKey: '', forcePathStyle: false,
  });
  assert.equal(aws.host, 'b.s3.eu-west-1.amazonaws.com');
  assert.equal(aws.basePath, '');

  const r2 = resolveEndpoint({
    endpoint: 'https://acct.r2.cloudflarestorage.com', region: 'auto',
    bucket: 'b', accessKeyId: '', secretAccessKey: '', forcePathStyle: true,
  });
  assert.equal(r2.host, 'acct.r2.cloudflarestorage.com');
  assert.equal(r2.basePath, '/b');
});

t('encodes each key segment without escaping the separators', () => {
  const url = presign({
    config: {
      endpoint: 'https://s3.test', region: 'us-east-1', bucket: 'b',
      accessKeyId: 'k', secretAccessKey: 's', forcePathStyle: true,
    },
    method: 'PUT', key: 'avatars/u 1/héllo (1).png', expiresIn: 60,
  });
  assert.ok(url.includes('/b/avatars/u%201/h%C3%A9llo%20%281%29.png'), url);
});

t('signed headers become part of the signature', () => {
  const config = {
    endpoint: 'https://s3.test', region: 'us-east-1', bucket: 'b',
    accessKeyId: 'k', secretAccessKey: 's', forcePathStyle: true,
  };
  const now = new Date(Date.UTC(2026, 0, 1));
  const plain = presign({ config, method: 'PUT', key: 'a.png', expiresIn: 60, now });
  const pinned = presign({
    config, method: 'PUT', key: 'a.png', expiresIn: 60, now,
    headers: { 'content-length': '10', 'content-type': 'image/png' },
  });
  assert.notEqual(
    new URL(plain).searchParams.get('X-Amz-Signature'),
    new URL(pinned).searchParams.get('X-Amz-Signature'),
  );
  assert.equal(
    new URL(pinned).searchParams.get('X-Amz-SignedHeaders'),
    'content-length;content-type;host',
  );
});

console.log(`\n${pass} signer checks passed`);
process.exit(process.exitCode ?? 0);
