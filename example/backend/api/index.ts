import { configError, loadEnv, route } from '../src/router.js';

export const config = { runtime: 'nodejs' };

export default async function handler(request: Request): Promise<Response> {
  try {
    return await route(request, loadEnv((key) => process.env[key]));
  } catch (error) {
    return configError(error);
  }
}
