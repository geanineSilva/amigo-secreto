-- Amigo Secreto: tabelas fechadas (RLS sem policies) + funções RPC por token.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.grupos (
  id uuid primary key default gen_random_uuid(),
  admin_token text not null unique default encode(extensions.gen_random_bytes(16), 'hex'),
  nome text not null check (char_length(nome) between 1 and 120),
  valor text,
  data_evento text,
  sorteado boolean not null default false,
  premium boolean not null default false, -- liberado manualmente após pagamento (grupos com mais de 10)
  criado_em timestamptz not null default now()
);

create table if not exists public.participantes (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  token text not null unique default encode(extensions.gen_random_bytes(16), 'hex'),
  nome text not null check (char_length(nome) between 1 and 80),
  contato text,
  desejos text not null default '',
  amigo_id uuid references public.participantes(id) on delete set null,
  criado_em timestamptz not null default now()
);
create index if not exists participantes_grupo_idx on public.participantes(grupo_id);
create index if not exists participantes_amigo_idx on public.participantes(amigo_id);

alter table public.grupos enable row level security;
alter table public.participantes enable row level security;
revoke all on public.grupos from anon, authenticated;
revoke all on public.participantes from anon, authenticated;

-- Criar grupo
create or replace function public.criar_grupo(p_nome text, p_valor text, p_data text)
returns json language plpgsql security definer set search_path = public as $$
declare g grupos;
begin
  insert into grupos(nome, valor, data_evento)
  values (trim(p_nome), nullif(trim(p_valor), ''), nullif(trim(p_data), ''))
  returning * into g;
  return json_build_object('admin_token', g.admin_token);
end $$;

-- Painel do organizador (não revela quem tirou quem)
create or replace function public.ver_grupo(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
declare g grupos;
begin
  select * into g from grupos where admin_token = p_admin;
  if not found then raise exception 'Grupo não encontrado'; end if;
  return json_build_object(
    'nome', g.nome, 'valor', g.valor, 'data_evento', g.data_evento, 'sorteado', g.sorteado,
    'premium', g.premium, 'codigo', left(g.id::text, 8),
    'participantes', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'nome', p.nome, 'contato', p.contato, 'token', p.token,
        'tem_desejos', p.desejos <> '') order by p.criado_em)
      from participantes p where p.grupo_id = g.id), '[]'::json));
end $$;

create or replace function public.adicionar_participante(p_admin text, p_nome text, p_contato text)
returns void language plpgsql security definer set search_path = public as $$
declare g grupos;
begin
  select * into g from grupos where admin_token = p_admin;
  if not found then raise exception 'Grupo não encontrado'; end if;
  if g.sorteado then raise exception 'O sorteio já foi feito. Desfaça o sorteio para adicionar pessoas.'; end if;
  if (select count(*) from participantes where grupo_id = g.id) >= (case when g.premium then 500 else 10 end) then
    raise exception using message = case when g.premium then 'Limite de 500 participantes'
      else 'LIMITE_GRATIS' end; end if;
  insert into participantes(grupo_id, nome, contato)
  values (g.id, trim(p_nome), nullif(trim(p_contato), ''));
end $$;

create or replace function public.remover_participante(p_admin text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g grupos;
begin
  select * into g from grupos where admin_token = p_admin;
  if not found then raise exception 'Grupo não encontrado'; end if;
  if g.sorteado then raise exception 'O sorteio já foi feito. Desfaça o sorteio para remover pessoas.'; end if;
  delete from participantes where id = p_id and grupo_id = g.id;
end $$;

-- Sorteio: embaralha e liga cada um ao próximo num ciclo único (ninguém tira a si mesmo)
create or replace function public.sortear(p_admin text)
returns void language plpgsql security definer set search_path = public as $$
declare g grupos; ids uuid[]; n int; i int;
begin
  select * into g from grupos where admin_token = p_admin for update;
  if not found then raise exception 'Grupo não encontrado'; end if;
  select array_agg(id order by gen_random_uuid()) into ids from participantes where grupo_id = g.id;
  n := coalesce(array_length(ids, 1), 0);
  if n < 3 then raise exception 'São necessárias pelo menos 3 pessoas para sortear'; end if;
  for i in 1..n loop
    update participantes set amigo_id = ids[(i % n) + 1] where id = ids[i];
  end loop;
  update grupos set sorteado = true where id = g.id;
end $$;

create or replace function public.desfazer_sorteio(p_admin text)
returns void language plpgsql security definer set search_path = public as $$
declare g grupos;
begin
  select * into g from grupos where admin_token = p_admin;
  if not found then raise exception 'Grupo não encontrado'; end if;
  update participantes set amigo_id = null where grupo_id = g.id;
  update grupos set sorteado = false where id = g.id;
end $$;

-- Página do participante
create or replace function public.ver_participante(p_token text)
returns json language plpgsql security definer set search_path = public as $$
declare p participantes; g grupos; a participantes;
begin
  select * into p from participantes where token = p_token;
  if not found then raise exception 'Link inválido'; end if;
  select * into g from grupos where id = p.grupo_id;
  if g.sorteado and p.amigo_id is not null then
    select * into a from participantes where id = p.amigo_id;
  end if;
  return json_build_object(
    'nome', p.nome, 'desejos', p.desejos,
    'grupo', g.nome, 'valor', g.valor, 'data_evento', g.data_evento, 'sorteado', g.sorteado,
    'amigo', case when a.id is null then null
             else json_build_object('nome', a.nome, 'desejos', a.desejos) end);
end $$;

create or replace function public.salvar_desejos(p_token text, p_desejos text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update participantes set desejos = left(coalesce(p_desejos, ''), 2000) where token = p_token;
  if not found then raise exception 'Link inválido'; end if;
end $$;

revoke all on function public.criar_grupo(text,text,text), public.ver_grupo(text),
  public.adicionar_participante(text,text,text), public.remover_participante(text,uuid),
  public.sortear(text), public.desfazer_sorteio(text), public.ver_participante(text),
  public.salvar_desejos(text,text) from public;
grant execute on function public.criar_grupo(text,text,text), public.ver_grupo(text),
  public.adicionar_participante(text,text,text), public.remover_participante(text,uuid),
  public.sortear(text), public.desfazer_sorteio(text), public.ver_participante(text),
  public.salvar_desejos(text,text) to anon, authenticated;

-- Pagamentos do Mercado Pago (liberação automática de grupos grandes)
create table if not exists public.pagamentos (
  mp_id bigint primary key,
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  status text not null,
  valor numeric(10,2) not null,
  qr_code text,
  qr_code_base64 text,
  expira_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists pagamentos_grupo_idx on public.pagamentos(grupo_id);
alter table public.pagamentos enable row level security;
revoke all on public.pagamentos from anon, authenticated;
