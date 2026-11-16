alter table public.participantes add column if not exists foto text;

-- Restrições: pares que não podem se tirar (vale nos dois sentidos)
create table if not exists public.restricoes (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  a_id uuid not null references public.participantes(id) on delete cascade,
  b_id uuid not null references public.participantes(id) on delete cascade,
  criado_em timestamptz not null default now(),
  check (a_id <> b_id)
);
create index if not exists restricoes_grupo_idx on public.restricoes(grupo_id);
alter table public.restricoes enable row level security;
revoke all on public.restricoes from anon, authenticated;

create or replace function public.adicionar_restricao(p_admin text, p_a uuid, p_b uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g grupos;
begin
  select * into g from grupos where admin_token = p_admin;
  if not found then raise exception 'Grupo não encontrado'; end if;
  if g.sorteado then raise exception 'O sorteio já foi feito. Desfaça o sorteio para mudar as restrições.'; end if;
  if p_a = p_b then raise exception 'Escolha duas pessoas diferentes'; end if;
  if (select count(*) from participantes where id in (p_a, p_b) and grupo_id = g.id) <> 2 then
    raise exception 'Participante não encontrado'; end if;
  if exists (select 1 from restricoes where grupo_id = g.id and ((a_id = p_a and b_id = p_b) or (a_id = p_b and b_id = p_a))) then
    return; end if;
  insert into restricoes(grupo_id, a_id, b_id) values (g.id, p_a, p_b);
end $$;

create or replace function public.remover_restricao(p_admin text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g grupos;
begin
  select * into g from grupos where admin_token = p_admin;
  if not found then raise exception 'Grupo não encontrado'; end if;
  if g.sorteado then raise exception 'O sorteio já foi feito. Desfaça o sorteio para mudar as restrições.'; end if;
  delete from restricoes where id = p_id and grupo_id = g.id;
end $$;

-- Organizador pode escrever/editar a lista de desejos de alguém
create or replace function public.salvar_desejos_admin(p_admin text, p_id uuid, p_desejos text)
returns void language plpgsql security definer set search_path = public as $$
declare g grupos;
begin
  select * into g from grupos where admin_token = p_admin;
  if not found then raise exception 'Grupo não encontrado'; end if;
  update participantes set desejos = left(coalesce(p_desejos, ''), 2000) where id = p_id and grupo_id = g.id;
end $$;

-- Painel: agora inclui as listas de desejos e as restrições (continua sem revelar quem tirou quem)
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
        'desejos', p.desejos, 'foto', p.foto, 'tem_desejos', p.desejos <> '') order by p.criado_em)
      from participantes p where p.grupo_id = g.id), '[]'::json),
    'restricoes', coalesce((
      select json_agg(json_build_object('id', r.id, 'a_id', r.a_id, 'b_id', r.b_id) order by r.criado_em)
      from restricoes r where r.grupo_id = g.id), '[]'::json));
end $$;

-- Sorteio respeitando as restrições: embaralha até achar uma combinação válida
create or replace function public.sortear(p_admin text)
returns void language plpgsql security definer set search_path = public as $$
declare g grupos; ids uuid[]; perm uuid[]; n int; i int; tentativa int; ok boolean;
begin
  select * into g from grupos where admin_token = p_admin for update;
  if not found then raise exception 'Grupo não encontrado'; end if;
  select array_agg(id order by criado_em) into ids from participantes where grupo_id = g.id;
  n := coalesce(array_length(ids, 1), 0);
  if n < 3 then raise exception 'São necessárias pelo menos 3 pessoas para sortear'; end if;
  for tentativa in 1..5000 loop
    select array_agg(x order by random()) into perm from unnest(ids) x;
    ok := true;
    for i in 1..n loop
      if perm[i] = ids[i] or exists (select 1 from restricoes r where r.grupo_id = g.id
           and ((r.a_id = ids[i] and r.b_id = perm[i]) or (r.a_id = perm[i] and r.b_id = ids[i]))) then
        ok := false; exit;
      end if;
    end loop;
    if ok then
      for i in 1..n loop
        update participantes set amigo_id = perm[i] where id = ids[i];
      end loop;
      update grupos set sorteado = true where id = g.id;
      return;
    end if;
  end loop;
  raise exception 'Não deu para sortear com essas restrições. Remova alguma e tente de novo.';
end $$;

revoke all on function public.adicionar_restricao(text,uuid,uuid), public.remover_restricao(text,uuid),
  public.salvar_desejos_admin(text,uuid,text) from public;
grant execute on function public.adicionar_restricao(text,uuid,uuid), public.remover_restricao(text,uuid),
  public.salvar_desejos_admin(text,uuid,text) to anon, authenticated;

-- Fotos: ver salvar_foto abaixo

create or replace function public.salvar_foto(p_token text, p_foto text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_foto is not null and p_foto <> '' and (p_foto not like 'data:image/%' or length(p_foto) > 300000) then
    raise exception 'Foto inválida ou grande demais'; end if;
  update participantes set foto = nullif(p_foto, '') where token = p_token;
  if not found then raise exception 'Link inválido'; end if;
end $$;

create or replace function public.salvar_foto_admin(p_admin text, p_id uuid, p_foto text)
returns void language plpgsql security definer set search_path = public as $$
declare g grupos;
begin
  select * into g from grupos where admin_token = p_admin;
  if not found then raise exception 'Grupo não encontrado'; end if;
  if p_foto is not null and p_foto <> '' and (p_foto not like 'data:image/%' or length(p_foto) > 300000) then
    raise exception 'Foto inválida ou grande demais'; end if;
  update participantes set foto = nullif(p_foto, '') where id = p_id and grupo_id = g.id;
end $$;

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
    'nome', p.nome, 'desejos', p.desejos, 'foto', p.foto,
    'grupo', g.nome, 'valor', g.valor, 'data_evento', g.data_evento, 'sorteado', g.sorteado,
    'amigo', case when a.id is null then null
             else json_build_object('nome', a.nome, 'desejos', a.desejos, 'foto', a.foto) end);
end $$;

revoke all on function public.salvar_foto(text,text), public.salvar_foto_admin(text,uuid,text) from public;
grant execute on function public.salvar_foto(text,text), public.salvar_foto_admin(text,uuid,text) to anon, authenticated;
