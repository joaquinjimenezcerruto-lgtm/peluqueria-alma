begin;

-- DUEÑOS DEL LOCAL
create table if not exists public.alma_owners (
  user_id uuid primary key
    references auth.users(id) on delete cascade
);

alter table public.alma_owners enable row level security;

revoke all on public.alma_owners from anon, authenticated;

create or replace function public.alma_is_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.alma_owners
    where user_id = (select auth.uid())
  );
$$;

revoke all on function public.alma_is_owner() from public;

grant execute on function public.alma_is_owner()
to authenticated;

-- Primero debes crear owner@prueba.com
-- en Authentication > Users de Supabase.
do $$
begin
  if not exists (
    select 1
    from auth.users
    where email = 'owner@prueba.com'
  ) then
    raise exception
      'Primero crea owner@prueba.com en Authentication > Users';
  end if;
end;
$$;

insert into public.alma_owners(user_id)
select id
from auth.users
where email = 'owner@prueba.com'
on conflict do nothing;


-- RESERVAS
create table if not exists public.alma_bookings (
  id uuid primary key default gen_random_uuid(),

  user_id uuid not null
    references auth.users(id) on delete cascade,

  client_name text not null
    check (char_length(client_name) between 2 and 100),

  service text not null
    check (
      service in (
        'Corte de cabello',
        'Peinado',
        'Tratamiento capilar'
      )
    ),

  starts_at timestamptz not null,

  status text not null default 'Activa'
    check (status in ('Activa', 'Cancelada')),

  created_at timestamptz not null default now(),

  constraint alma_business_hours check (
    extract(
      isodow from starts_at at time zone 'America/Guayaquil'
    ) between 1 and 6

    and extract(
      hour from starts_at at time zone 'America/Guayaquil'
    ) between 9 and 17

    and extract(
      minute from starts_at at time zone 'America/Guayaquil'
    ) = 0

    and extract(
      second from starts_at at time zone 'America/Guayaquil'
    ) = 0
  )
);

-- Impide dos reservas activas en el mismo horario.
create unique index if not exists alma_unique_slot
on public.alma_bookings(starts_at)
where status = 'Activa';

create index if not exists alma_bookings_user
on public.alma_bookings(user_id);

alter table public.alma_bookings enable row level security;

revoke all on public.alma_bookings from anon, authenticated;

grant select, insert
on public.alma_bookings to authenticated;

grant update(starts_at, status)
on public.alma_bookings to authenticated;


-- Cada cliente ve sus citas; el dueño ve todas.
drop policy if exists alma_booking_read
on public.alma_bookings;

create policy alma_booking_read
on public.alma_bookings
for select
to authenticated
using (
  user_id = (select auth.uid())
  or (select public.alma_is_owner())
);


-- Los clientes solo crean reservas para sí mismos.
drop policy if exists alma_booking_create
on public.alma_bookings;

create policy alma_booking_create
on public.alma_bookings
for insert
to authenticated
with check (
  user_id = (select auth.uid())
  and not (select public.alma_is_owner())
  and status = 'Activa'
  and starts_at > now()
  and starts_at <= now() + interval '60 days'
);


-- Solo el dueño modifica o cancela reservas.
drop policy if exists alma_booking_manage
on public.alma_bookings;

create policy alma_booking_manage
on public.alma_bookings
for update
to authenticated
using (
  (select public.alma_is_owner())
)
with check (
  (select public.alma_is_owner())
);


-- MENSAJES DEL CHAT
create table if not exists public.alma_messages (
  id uuid primary key default gen_random_uuid(),

  booking_id uuid not null
    references public.alma_bookings(id) on delete cascade,

  author_id uuid not null
    references auth.users(id) on delete cascade,

  body text not null
    check (char_length(body) between 1 and 2000),

  created_at timestamptz not null default now()
);

create index if not exists alma_messages_booking
on public.alma_messages(booking_id, created_at);

alter table public.alma_messages enable row level security;

revoke all on public.alma_messages from anon, authenticated;

grant select, insert
on public.alma_messages to authenticated;


-- Solo el cliente de la cita y el dueño leen el chat.
drop policy if exists alma_message_read
on public.alma_messages;

create policy alma_message_read
on public.alma_messages
for select
to authenticated
using (
  exists (
    select 1
    from public.alma_bookings b
    where b.id = booking_id
      and (
        b.user_id = (select auth.uid())
        or (select public.alma_is_owner())
      )
  )
);


-- Cada persona escribe con su propia identidad.
drop policy if exists alma_message_send
on public.alma_messages;

create policy alma_message_send
on public.alma_messages
for insert
to authenticated
with check (
  author_id = (select auth.uid())
  and exists (
    select 1
    from public.alma_bookings b
    where b.id = booking_id
      and (
        b.user_id = (select auth.uid())
        or (select public.alma_is_owner())
      )
  )
);


-- DIRECCIÓN Y CONTACTO DEL LOCAL
create table if not exists public.alma_settings (
  id integer primary key check (id = 1),

  address text not null
    check (char_length(address) between 5 and 300),

  contact text not null
    check (char_length(contact) <= 200)
);

insert into public.alma_settings(id, address, contact)
values (
  1,
  'Quito, Ecuador — dirección exacta pendiente',
  'Contacto pendiente'
)
on conflict do nothing;

alter table public.alma_settings enable row level security;

revoke all on public.alma_settings from anon, authenticated;

grant select
on public.alma_settings to anon, authenticated;

grant update(address, contact)
on public.alma_settings to authenticated;


-- Cualquier visitante puede consultar la ubicación.
drop policy if exists alma_settings_read
on public.alma_settings;

create policy alma_settings_read
on public.alma_settings
for select
to anon, authenticated
using (true);


-- Solo el dueño cambia la dirección y el contacto.
drop policy if exists alma_settings_manage
on public.alma_settings;

create policy alma_settings_manage
on public.alma_settings
for update
to authenticated
using (
  (select public.alma_is_owner())
)
with check (
  (select public.alma_is_owner())
);


-- HORARIOS DISPONIBLES
-- Muestra horas libres sin revelar datos de clientes.
create or replace function public.alma_available_slots(p_day date)
returns table(slot text)
language sql
stable
security definer
set search_path = ''
as $$
  select to_char(
    candidate.starts_at at time zone 'America/Guayaquil',
    'HH24:MI'
  ) as slot

  from (
    select
      (p_day + make_time(h, 0, 0))
        at time zone 'America/Guayaquil' as starts_at
    from generate_series(9, 17) as hours(h)
  ) candidate

  where extract(isodow from p_day) between 1 and 6

    and candidate.starts_at > now()

    and candidate.starts_at <= now() + interval '60 days'

    and not exists (
      select 1
      from public.alma_bookings b
      where b.starts_at = candidate.starts_at
        and b.status = 'Activa'
    )

  order by candidate.starts_at;
$$;

revoke all
on function public.alma_available_slots(date)
from public;

grant execute
on function public.alma_available_slots(date)
to anon, authenticated;

commit;