import { handleUpload, readEnv } from '../lib/core';

export async function POST(request: Request): Promise<Response> {
  return handleUpload(request, readEnv((key) => process.env[key]));
}
