-- Виконай цілком у Supabase: SQL Editor -> New query -> Run.
-- ПЕРЕД запуском заміни два email у кінці файлу на ваші (ті, що додаси в Authentication -> Users).

create table members(user_id uuid primary key references auth.users on delete cascade, role text unique check (role in ('m','f')));
create table wishes(id uuid primary key default gen_random_uuid(), by_role text not null check (by_role in ('m','f')),
  text text not null check (char_length(text) between 1 and 200), created_at timestamptz default now(),
  done boolean not null default false, done_at timestamptz);
create unique index wishes_text_uq on wishes (lower(btrim(text)));          -- одне бажання один раз
create table picks(month text, for_role text, ids uuid[] not null, picker text not null, mode text not null,
  created_at timestamptz default now(), primary key(month, for_role));

create function my_role() returns text language sql stable security definer set search_path=public as
$$ select role from members where user_id = auth.uid() $$;

alter table members enable row level security; alter table wishes enable row level security; alter table picks enable row level security;
create policy mem_sel on members for select to authenticated using (user_id = auth.uid());
create policy w_sel on wishes for select to authenticated using (my_role() is not null);
create policy w_ins on wishes for insert to authenticated with check (by_role = my_role() and not done);
create policy w_del on wishes for delete to authenticated using (by_role = my_role() and not done
  and not exists (select 1 from picks p where wishes.id = any(p.ids)));
create policy p_sel on picks for select to authenticated using (my_role() is not null);
-- змінювати picks та позначати "виконано" можна ЛИШЕ через функції нижче

create function make_pick(manual uuid[]) returns void language plpgsql security definer set search_path=public as $$
declare me text := my_role(); tgt text; m text := to_char(now() at time zone 'Europe/Kyiv','YYYY-MM'); rest uuid[]; k int;
begin
  if me is null then raise exception 'Немає доступу'; end if;
  tgt := case when me='m' then 'f' else 'm' end;
  manual := coalesce(manual, '{}'); k := cardinality(manual);
  if exists (select 1 from picks where month=m and for_role=tgt) then raise exception 'Цього місяця вибір уже зроблено'; end if;
  if k not in (0,2) then raise exception 'Обери 0 (усе випадково) або рівно 2 бажання'; end if;
  if (select count(distinct x) from unnest(manual) x) <> k then raise exception 'Бажання повторюються'; end if;
  if exists (select 1 from unnest(manual) u where not exists (select 1 from wishes w where w.id=u and w.by_role=tgt and not w.done))
    then raise exception 'Некоректне бажання'; end if;
  select coalesce(array_agg(id), '{}') into rest from (select id from wishes where by_role=tgt and not done
    and id <> all(manual) order by random() limit 3-k) s;
  if cardinality(rest) < 3-k then raise exception 'Недостатньо невиконаних бажань (потрібно щонайменше 3)'; end if;
  insert into picks values (m, tgt, manual || rest, me, case when k=0 then 'random' else 'mix' end, now());
end $$;

create function mark_done(wid uuid) returns void language plpgsql security definer set search_path=public as $$
declare m text := to_char(now() at time zone 'Europe/Kyiv','YYYY-MM');
begin
  update wishes set done=true, done_at=now()
   where id=wid and by_role=my_role() and not done
     and exists (select 1 from picks p where p.month=m and p.for_role=wishes.by_role and wid = any(p.ids));
  if not found then raise exception 'Не можна відмітити це бажання'; end if;
end $$;

revoke execute on function make_pick(uuid[]), mark_done(uuid), my_role() from public, anon;
grant execute on function make_pick(uuid[]), mark_done(uuid), my_role() to authenticated;

-- ЗАМІНИ email: перший — партнер (♂), другий — партнерка (♀)
insert into members select id, 'm' from auth.users where email = 'valeproffesional@gmail.com';
insert into members select id, 'f' from auth.users where email = 'valentindubilej@gmail.com';
