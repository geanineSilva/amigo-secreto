// Gera (ou reaproveita) um Pix do Mercado Pago para liberar um grupo grande.
import { createClient } from "npm:@supabase/supabase-js@2";

const PRECO = 9.9;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ message: "Método não permitido" }, 405);

  const token = (Deno.env.get("MP_ACCESS_TOKEN") || "").replace(/^\s*(MP_ACCESS_TOKEN\s*=\s*)?(Bearer\s+)?["']?/i, "").replace(/["']?\s*$/, "");
  console.log("token ok?", token.startsWith("APP_USR-"), token.length);
  if (!token) return json({ message: "Pagamento ainda não configurado" }, 503);

  let body: { admin_token?: string; email?: string };
  try { body = await req.json(); } catch { return json({ message: "Pedido inválido" }, 400); }
  const email = String(body.email || "").trim().toLowerCase();
  if (!body.admin_token || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ message: "Informe um e-mail válido" }, 400);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: g } = await db.from("grupos").select("id, premium").eq("admin_token", body.admin_token).maybeSingle();
  if (!g) return json({ message: "Grupo não encontrado" }, 404);
  if (g.premium) return json({ premium: true });

  // Reaproveita um Pix pendente que ainda vale por mais de 5 minutos
  const { data: pend } = await db.from("pagamentos").select("*").eq("grupo_id", g.id).eq("status", "pending")
    .gt("expira_em", new Date(Date.now() + 5 * 60_000).toISOString()).order("criado_em", { ascending: false }).limit(1).maybeSingle();
  if (pend) return json({ qr_code: pend.qr_code, qr_code_base64: pend.qr_code_base64, valor: pend.valor });

  const expira = new Date(Date.now() + 30 * 60_000);
  const r = await fetch("https://api.mercadopago.com/v1/payments", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "X-Idempotency-Key": crypto.randomUUID() },
    body: JSON.stringify({
      transaction_amount: PRECO,
      description: "Amigo Secreto - liberar grupo grande",
      payment_method_id: "pix",
      payer: { email },
      external_reference: g.id,
      notification_url: `${Deno.env.get("SUPABASE_URL")}/functions/v1/pix-webhook`,
      date_of_expiration: expira.toISOString().replace("Z", "-00:00"),
    }),
  });
  const p = await r.json();
  if (!r.ok) {
    console.error("MP erro", r.status, JSON.stringify(p));
    return json({ message: "Não foi possível gerar o Pix agora. Tente de novo em instantes." }, 502);
  }
  const td = p.point_of_interaction?.transaction_data ?? {};
  await db.from("pagamentos").upsert({
    mp_id: p.id, grupo_id: g.id, status: p.status, valor: p.transaction_amount,
    qr_code: td.qr_code, qr_code_base64: td.qr_code_base64, expira_em: expira.toISOString(),
  });
  return json({ qr_code: td.qr_code, qr_code_base64: td.qr_code_base64, valor: p.transaction_amount });
});
