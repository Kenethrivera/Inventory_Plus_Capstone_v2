import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const headers = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json',
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers });

function internationalPhone(raw: string): string | null {
  const clean = raw.replace(/[\s().-]/g, '');
  const number = clean.startsWith('09') && clean.length === 11
    ? `+63${clean.slice(1)}`
    : clean.startsWith('63') ? `+${clean}` : clean;
  return /^\+[1-9]\d{7,14}$/.test(number) ? number : null;
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers });
  if (request.method !== 'POST') return reply({ error: 'Method not allowed' }, 405);
  const url = Deno.env.get('SUPABASE_URL');
  let serviceKey: string | undefined;
  try {
    const keys = Deno.env.get('SUPABASE_SECRET_KEYS');
    serviceKey = keys ? JSON.parse(keys)?.default : undefined;
  } catch (_) {
    console.error('Invalid Supabase secret key configuration');
  }
  serviceKey ??= Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? undefined;
  if (!url || !serviceKey) return reply({ error: 'Recovery is unavailable' }, 503);

  let body: Record<string, unknown>;
  try {
    body = await request.json();
    if (!body || typeof body !== 'object') throw new Error('Invalid request');
  } catch (_) {
    return reply({ error: 'Invalid request' }, 400);
  }
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const action = body.action;
  try {
    if (action === 'request') {
      const username = typeof body.username === 'string' ? body.username.trim() : '';
      const channel = body.channel === 'sms' ? 'sms' : null;
      if (!username || username.length > 128) return reply({ error: 'Invalid username' }, 400);
      if (!channel) return reply({ error: 'Invalid channel' }, 400);
      if (!Deno.env.get('TEXTBEE_API_KEY')) {
        return reply({ error: 'SMS recovery is not configured' }, 503);
      }
      const { data, error } = await admin.rpc('password_recovery_begin_v1', {
        p_username: username, p_channel: channel,
      });
      if (error) throw error;
      const challengeId = data?.challenge_id ?? crypto.randomUUID();
      if (data?.challenge_id) {
        let accepted = false;
        try {
          const phone = internationalPhone(String(data.destination ?? ''));
          if (phone) {
            const payload: Record<string, unknown> = {
              recipients: [phone],
              message: `Inventory Plus password reset code: ${data.code}. Expires in 10 minutes. Do not share it.`,
            };
            const deviceId = Deno.env.get('TEXTBEE_DEVICE_ID')?.trim();
            if (deviceId) payload.deviceId = deviceId;
            const response = await fetch('https://api.textbee.dev/api/v1/gateway/send-sms', {
              method: 'POST',
              headers: { 'x-api-key': Deno.env.get('TEXTBEE_API_KEY')!, 'Content-Type': 'application/json' },
              body: JSON.stringify(payload),
              signal: AbortSignal.timeout(10000),
            });
            const result = await response.json().catch(() => null);
            accepted = response.ok && result?.data?.success === true;
            if (!accepted) console.error('Textbee rejected recovery SMS', response.status);
          }
        } catch (deliveryError) {
          console.error('Recovery delivery failed', deliveryError);
        }
        if (!accepted) {
          await admin.rpc('password_recovery_cancel_v1', {
            p_challenge_id: challengeId,
          });
        }
      }
      // The same response for unknown, throttled, and eligible accounts.
      return reply({ challengeId });
    }
    if (action === 'verify') {
      const challengeId = typeof body.challengeId === 'string' ? body.challengeId : '';
      const code = typeof body.code === 'string' ? body.code : '';
      if (!/^[0-9a-f-]{36}$/i.test(challengeId) || !/^\d{6}$/.test(code)) {
        return reply({ resetToken: null });
      }
      const { data, error } = await admin.rpc('password_recovery_verify_v1', {
        p_challenge_id: challengeId, p_code: code,
      });
      if (error) throw error;
      return reply({ resetToken: data });
    }
    if (action === 'complete') {
      const token = typeof body.resetToken === 'string' ? body.resetToken : '';
      const password = typeof body.password === 'string' ? body.password : '';
      if (!/^[0-9a-f]{64}$/i.test(token) || password.length > 128) {
        return reply({ success: false });
      }
      const { data, error } = await admin.rpc('password_recovery_complete_v1', {
        p_reset_token: token, p_new_password: password,
      });
      if (error) throw error;
      return reply({ success: data === true });
    }
    return reply({ error: 'Unknown action' }, 400);
  } catch (error) {
    console.error('Password recovery failed', error);
    return reply({ error: 'Recovery is temporarily unavailable' }, 503);
  }
});
