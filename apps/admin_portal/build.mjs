import { mkdir, cp, rm, writeFile } from 'node:fs/promises';
import { env } from 'node:process';
await rm('dist', { recursive: true, force: true });
await mkdir('dist', { recursive: true });
await cp('src', 'dist', { recursive: true });
const production = env.ADMIN_PORTAL_ENV === 'production';
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
await writeFile('dist/config.js', `globalThis.INSIGHTFLOW_ADMIN_CONFIG=${JSON.stringify(config)};`);
