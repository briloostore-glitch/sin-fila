-- Sin Fila - esquema v2. Ejecutar una sola vez en un proyecto nuevo.

-- ========== CATALOGO ==========
create table public.cities (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  department text,
  center_lat double precision not null,
  center_lng double precision not null,
  radius_km numeric not null default 25,
  active boolean not null default false
);

create table public.zones (
  id uuid primary key default gen_random_uuid(),
  city_id uuid not null references public.cities(id) on delete cascade,
  name text not null,
  active boolean not null default true
);

create table public.entities (
  id uuid primary key default gen_random_uuid(),
  city_id uuid not null references public.cities(id) on delete cascade,
  zone_id uuid references public.zones(id) on delete set null,
  name text not null,
  address text,
  lat double precision,
  lng double precision,
  active boolean not null default true
);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  active boolean not null default true
);

create table public.tariffs (
  id uuid primary key default gen_random_uuid(),
  city_id uuid not null references public.cities(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  entity_id uuid references public.entities(id) on delete cascade,
  price_cop integer not null check (price_cop >= 0),
  commission_pct numeric not null default 20 check (commission_pct between 0 and 100)
);

create unique index tariffs_unique_idx on public.tariffs
  (city_id, service_id, coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- ========== USUARIOS ==========
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'client' check (role in ('client','courier','admin')),
  full_name text,
  phone text,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.my_role() returns text
language sql security definer stable set search_path = public as $$
  select role from public.profiles where id = auth.uid();
$$;

-- Todo usuario nuevo entra como client; el rol solo lo cambia un admin
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data->>'full_name');
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create table public.couriers (
  id uuid primary key references public.profiles(id) on delete cascade,
  city_id uuid not null references public.cities(id),
  available boolean not null default false,
  approved boolean not null default false,
  last_lat double precision,
  last_lng double precision,
  last_seen timestamptz
);

-- ========== PEDIDOS ==========
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id),
  courier_id uuid references public.couriers(id),
  city_id uuid not null references public.cities(id),
  service_id uuid not null references public.services(id),
  entity_id uuid references public.entities(id),
  status text not null default 'pending'
    check (status in ('pending','accepted','on_the_way','in_line','completed','cancelled')),
  price_cop integer not null,
  commission_pct numeric not null,
  notes text,
  created_at timestamptz not null default now()
);

create index orders_client_idx on public.orders (client_id);
create index orders_courier_idx on public.orders (courier_id);
create index orders_city_status_idx on public.orders (city_id, status);

create table public.order_events (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  status text not null,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.order_evidence (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  file_path text not null,
  note text,
  uploaded_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  amount_cop integer not null,
  method text,
  status text not null default 'pending' check (status in ('pending','paid','refunded')),
  created_at timestamptz not null default now()
);

-- ========== CIUDAD MAS CERCANA (haversine) ==========
create or replace function public.nearest_city(p_lat double precision, p_lng double precision)
returns table (id uuid, name text, distance_km double precision, within_radius boolean)
language sql stable set search_path = public as $$
  select s.id, s.name, s.distance_km, s.distance_km <= s.radius_km
  from (
    select c.id, c.name, c.radius_km,
      2 * 6371 * asin(sqrt(least(1,
        power(sin(radians(p_lat - c.center_lat) / 2), 2) +
        cos(radians(c.center_lat)) * cos(radians(p_lat)) *
        power(sin(radians(p_lng - c.center_lng) / 2), 2)
      ))) as distance_km
    from public.cities c
    where c.active
  ) s
  order by s.distance_km
  limit 1;
$$;

-- ========== FUNCIONES DE NEGOCIO ==========
create or replace function public.create_order(
  p_city uuid, p_service uuid, p_entity uuid, p_notes text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  t public.tariffs%rowtype;
  new_id uuid;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesion'; end if;
  if not exists (select 1 from public.cities where id = p_city and active) then
    raise exception 'Ciudad no disponible';
  end if;

  select * into t from public.tariffs
  where city_id = p_city and service_id = p_service
    and (entity_id = p_entity or entity_id is null)
  order by (entity_id is not null) desc
  limit 1;
  if not found then raise exception 'No hay tarifa para este servicio'; end if;

  insert into public.orders (client_id, city_id, service_id, entity_id, price_cop, commission_pct, notes)
  values (auth.uid(), p_city, p_service, p_entity, t.price_cop, t.commission_pct, p_notes)
  returning id into new_id;

  insert into public.order_events (order_id, status, created_by)
  values (new_id, 'pending', auth.uid());

  return new_id;
end $$;

create or replace function public.set_order_status(p_order uuid, p_status text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  o public.orders%rowtype;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Debes iniciar sesion'; end if;
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Pedido no encontrado'; end if;

  if public.is_admin() then
    update public.orders set status = p_status where id = p_order;
  elsif p_status = 'accepted' and o.status = 'pending' then
    if not exists (
      select 1 from public.couriers
      where id = uid and approved and city_id = o.city_id
    ) then
      raise exception 'No puedes aceptar este pedido';
    end if;
    update public.orders set status = 'accepted', courier_id = uid where id = p_order;
  elsif o.courier_id = uid and (
      (o.status = 'accepted' and p_status = 'on_the_way') or
      (o.status = 'on_the_way' and p_status = 'in_line') or
      (o.status = 'in_line' and p_status = 'completed')
  ) then
    update public.orders set status = p_status where id = p_order;
  elsif o.client_id = uid and o.status in ('pending','accepted') and p_status = 'cancelled' then
    update public.orders set status = 'cancelled' where id = p_order;
  else
    raise exception 'Cambio de estado no permitido';
  end if;

  insert into public.order_events (order_id, status, created_by)
  values (p_order, p_status, uid);
end $$;

create or replace function public.courier_update_status(
  p_available boolean, p_lat double precision, p_lng double precision
) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.couriers
  set available = p_available, last_lat = p_lat, last_lng = p_lng, last_seen = now()
  where id = auth.uid() and approved;
  if not found then raise exception 'Mensajero no encontrado o no aprobado'; end if;
end $$;

revoke all on function public.create_order(uuid, uuid, uuid, text) from public, anon;
revoke all on function public.set_order_status(uuid, text) from public, anon;
revoke all on function public.courier_update_status(boolean, double precision, double precision) from public, anon;
grant execute on function public.create_order(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.set_order_status(uuid, text) to authenticated;
grant execute on function public.courier_update_status(boolean, double precision, double precision) to authenticated;
grant execute on function public.nearest_city(double precision, double precision) to anon, authenticated;

-- ========== RLS ==========
alter table public.cities enable row level security;
alter table public.zones enable row level security;
alter table public.entities enable row level security;
alter table public.services enable row level security;
alter table public.tariffs enable row level security;
alter table public.profiles enable row level security;
alter table public.couriers enable row level security;
alter table public.orders enable row level security;
alter table public.order_events enable row level security;
alter table public.order_evidence enable row level security;
alter table public.payments enable row level security;

-- Catalogo: lectura publica, escritura solo admin
create policy cities_read on public.cities for select using (true);
create policy zones_read on public.zones for select using (true);
create policy entities_read on public.entities for select using (true);
create policy services_read on public.services for select using (true);
create policy tariffs_read on public.tariffs for select using (true);
create policy cities_admin on public.cities for all using (public.is_admin()) with check (public.is_admin());
create policy zones_admin on public.zones for all using (public.is_admin()) with check (public.is_admin());
create policy entities_admin on public.entities for all using (public.is_admin()) with check (public.is_admin());
create policy services_admin on public.services for all using (public.is_admin()) with check (public.is_admin());
create policy tariffs_admin on public.tariffs for all using (public.is_admin()) with check (public.is_admin());

-- Perfiles
create policy profiles_select on public.profiles for select
  using (id = auth.uid() or public.is_admin());
create policy profiles_update_own on public.profiles for update
  using (id = auth.uid())
  with check (id = auth.uid() and role = public.my_role());
create policy profiles_admin on public.profiles for all
  using (public.is_admin()) with check (public.is_admin());

-- Mensajeros: ven su fila; solo admin escribe (el mensajero usa courier_update_status)
create policy couriers_select on public.couriers for select
  using (id = auth.uid() or public.is_admin());
create policy couriers_admin on public.couriers for all
  using (public.is_admin()) with check (public.is_admin());

-- Pedidos: se crean y cambian solo por funciones; aqui solo lectura
create policy orders_select on public.orders for select using (
  client_id = auth.uid()
  or courier_id = auth.uid()
  or public.is_admin()
);
create policy orders_pending_for_couriers on public.orders for select using (
  status = 'pending' and exists (
    select 1 from public.couriers c
    where c.id = auth.uid() and c.approved and c.available and c.city_id = orders.city_id
  )
);
create policy orders_admin on public.orders for all
  using (public.is_admin()) with check (public.is_admin());

create policy events_select on public.order_events for select
  using (exists (select 1 from public.orders o where o.id = order_id));
create policy events_admin on public.order_events for all
  using (public.is_admin()) with check (public.is_admin());

create policy evidence_select on public.order_evidence for select
  using (exists (select 1 from public.orders o where o.id = order_id));
create policy evidence_insert on public.order_evidence for insert
  with check (
    uploaded_by = auth.uid()
    and exists (select 1 from public.orders o where o.id = order_id and o.courier_id = auth.uid())
  );
create policy evidence_admin on public.order_evidence for all
  using (public.is_admin()) with check (public.is_admin());

create policy payments_select on public.payments for select using (
  public.is_admin()
  or exists (select 1 from public.orders o where o.id = order_id and o.client_id = auth.uid())
);
create policy payments_admin on public.payments for all
  using (public.is_admin()) with check (public.is_admin());

-- ========== PERMISOS DE LA API (RLS decide quien ve y escribe que) ==========
grant usage on schema public to anon, authenticated;
grant select on public.cities, public.zones, public.entities, public.services, public.tariffs to anon;
grant select, insert, update, delete on all tables in schema public to authenticated;

-- ========== STORAGE: evidencias (ruta: <order_id>/<archivo>) ==========
insert into storage.buckets (id, name, public)
values ('evidence', 'evidence', false)
on conflict (id) do nothing;

drop policy if exists evidence_files_read on storage.objects;
drop policy if exists evidence_files_insert on storage.objects;

create policy evidence_files_read on storage.objects for select to authenticated
using (
  bucket_id = 'evidence' and (
    public.is_admin()
    or exists (select 1 from public.orders o where o.id::text = (storage.foldername(name))[1])
  )
);

create policy evidence_files_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'evidence' and (
    public.is_admin()
    or exists (
      select 1 from public.orders o
      where o.id::text = (storage.foldername(name))[1] and o.courier_id = auth.uid()
    )
  )
);