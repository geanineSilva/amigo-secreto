// Recebe o aviso do Mercado Pago, confere o pagamento direto na API e libera o grupo.
import { createClient } from "npm:@supabase/supabase-js@2";

const PRECO = 9.9;

Deno.serve(async (req) => {
  const url = new URL(req.url);
  let id = url.searchParams.get("data.id") || url.searchParams.get("id");
  let tipo = url.searchParams.get("type") || url.searchParams.get("topic");
  if (req.method === "POST") {
    try {
      const b = await req.json();
      id = String(b?.data?.id ?? id ?? "");
      tipo = b?.type ?? tipo;
    } catch { /* corpo vazio */ }
  }
  if (!id || (tipo && tipo !== "payment")) return new Response("ignorado", { status: 200 });

  const token = Deno.env.get("MP_ACCESS_TOKEN");
  if (!token) return new Response("sem token", { status: 200 });

  // Nunca confia no corpo do aviso: busca o pagamento no Mercado Pago
  const r = await fetch(`https://api.mercadopago.com/v1/payments/${encodeURIComponent(id)}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!r.ok) { console.error("MP consulta", r.status); return new Response("erro", { status: 500 }); }
  const p = await r.json();

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  await db.from("pagamentos").update({ status: p.status, atualizado_em: new Date().toISOString() }).eq("mp_id", p.id);

  if (p.status === "approved" && Number(p.transaction_amount) >= PRECO && p.external_reference) {
    const { error } = await db.from("grupos").update({ premium: true }).eq("id", p.external_reference);
    if (error) { console.error(error); return new Response("erro", { status: 500 }); }
    console.log("grupo liberado", p.external_reference, p.id);
  }
  return new Response("ok", { status: 200 });
});
