const config = window.TAILOR_CONNECT_CONFIG || {};
export const configured = Boolean(config.supabaseUrl && config.supabasePublishableKey && window.supabase);
export const db = configured ? window.supabase.createClient(config.supabaseUrl, config.supabasePublishableKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
}) : null;

export function requireDb() {
  if (!db) throw new Error('SUPABASE_NOT_CONFIGURED');
  return db;
}
