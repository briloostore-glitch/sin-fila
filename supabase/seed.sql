insert into public.cities (name, department, center_lat, center_lng, radius_km, active)
select v.name, v.department, v.center_lat, v.center_lng, v.radius_km, v.active
from (values
  ('Pereira',   'Risaralda',       4.8133, -75.6961, 25, true),
  ('Armenia',   'Quindio',         4.5339, -75.6811, 25, false),
  ('Manizales', 'Caldas',          5.0703, -75.5138, 25, false),
  ('Medellin',  'Antioquia',       6.2442, -75.5812, 30, false),
  ('Bogota',    'Cundinamarca',    4.7110, -74.0721, 40, false),
  ('Cali',      'Valle del Cauca', 3.4516, -76.5320, 30, false)
) as v(name, department, center_lat, center_lng, radius_km, active)
where not exists (select 1 from public.cities c where c.name = v.name);

insert into public.zones (city_id, name)
select c.id, z.name
from public.cities c
cross join (values ('Centro'), ('Cuba'), ('Circunvalar'), ('Álamos'), ('Dosquebradas'), ('Pinares')) as z(name)
where c.name = 'Pereira'
  and not exists (select 1 from public.zones x where x.city_id = c.id and x.name = z.name);

insert into public.entities (city_id, name)
select c.id, e.name
from public.cities c
cross join (values
  ('Cámara de Comercio'), ('Notaría'), ('EPS (sede principal)'),
  ('Alcaldía / Tránsito'), ('Banco o ventanilla de pago')
) as e(name)
where c.name = 'Pereira'
  and not exists (select 1 from public.entities x where x.city_id = c.id and x.name = e.name);

insert into public.services (name)
select v.name
from (values
  ('Entrega y radicación de documentos'),
  ('Pago de facturas, impuestos o multas'),
  ('Fila o cita en EPS'),
  ('Reclamar certificados ya listos'),
  ('Renovación de registro mercantil')
) as v(name)
where not exists (select 1 from public.services s where s.name = v.name);

insert into public.tariffs (city_id, service_id, price_cop, commission_pct)
select c.id, s.id, v.price, 25
from (values
  ('Entrega y radicación de documentos', 20000),
  ('Pago de facturas, impuestos o multas', 15000),
  ('Fila o cita en EPS', 30000),
  ('Reclamar certificados ya listos', 25000),
  ('Renovación de registro mercantil', 50000)
) as v(sname, price)
join public.services s on s.name = v.sname
join public.cities c on c.name = 'Pereira'
where not exists (
  select 1 from public.tariffs t
  where t.city_id = c.id and t.service_id = s.id and t.entity_id is null
);

update public.services set active = false
where name in ('Fila en notaria', 'Pago de servicios', 'Radicacion de documentos');

update public.zones z set active = false
from public.cities c
where c.id = z.city_id and c.name <> 'Pereira';