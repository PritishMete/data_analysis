import { mkdir, cp, rm, writeFile, readFile } from 'node:fs/promises';
import { env } from 'node:process';
await rm('dist', { recursive: true, force: true });
await mkdir('dist', { recursive: true });
await cp('src', 'dist', { recursive: true });
const mode = env.ADMIN_PORTAL_ENV;
if (!['production', 'development', 'test'].includes(mode)) {
  throw new Error('ADMIN_PORTAL_ENV must be explicitly set to production, development, or test.');
}
const production = mode === 'production';
const values = {
  apiOrigin: env.INSIGHTFLOW_ADMIN_API,
  supabaseUrl: env.INSIGHTFLOW_SUPABASE_URL,
  supabaseAnonKey: env.INSIGHTFLOW_SUPABASE_ANON_KEY,
};
if (production && Object.values(values).some(value => !value)) {
  throw new Error('Production admin build requires INSIGHTFLOW_ADMIN_API, INSIGHTFLOW_SUPABASE_URL, and INSIGHTFLOW_SUPABASE_ANON_KEY.');
}
if (Object.keys(env).some(key => /INSIGHTFLOW_(?:SUPABASE_SERVICE_ROLE_KEY|DATABASE_PASSWORD)/i.test(key))) {
  throw new Error('Server secrets must not be supplied to the admin frontend build.');
}
const config = production ? values : {
  apiOrigin: values.apiOrigin || 'http://localhost:8000',
  supabaseUrl: values.supabaseUrl || '',
  supabaseAnonKey: values.supabaseAnonKey || '',
};
for (const [name, value] of Object.entries({ apiOrigin: config.apiOrigin, supabaseUrl: config.supabaseUrl })) {
  if (!value) continue;
  let parsed;
  try { parsed = new URL(value); } catch { throw new Error(`${name} must be a valid URL.`); }
  if (production && parsed.protocol !== 'https:') throw new Error(`${name} must use HTTPS in production.`);
  if (parsed.username || parsed.password || parsed.search || parsed.hash) throw new Error(`${name} must not contain credentials, query parameters, or fragments.`);
  if (!parsed.hostname) throw new Error(`${name} must include a hostname.`);
  if (name === 'apiOrigin' && parsed.pathname !== '/') throw new Error('apiOrigin must be an origin without a path.');
  if (name === 'apiOrigin') config.apiOrigin = parsed.origin;
}
const headersTemplate = await readFile('_headers', 'utf8');
const apiOrigin = new URL(config.apiOrigin).origin;
const headers = headersTemplate.replaceAll('__INSIGHTFLOW_ADMIN_API_ORIGIN__', apiOrigin);
if (headers.includes('__INSIGHTFLOW_ADMIN_API_ORIGIN__')) {
  throw new Error('Admin API origin was not substituted into the Pages security headers.');
}
await writeFile('dist/_headers', headers);
await writeFile('dist/config.js', `globalThis.INSIGHTFLOW_ADMIN_CONFIG=${JSON.stringify(config)};`);
