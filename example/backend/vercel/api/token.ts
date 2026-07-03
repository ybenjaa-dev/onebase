import { handleToken, readEnv } from '../lib/core';

export async function POST(request: Request): Promise<Response> {
  return handleToken(request, readEnv((key) => process.env[key]));
}
