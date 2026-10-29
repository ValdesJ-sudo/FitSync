-- =====================================================================
--  GymApp · esquema inicial (Supabase / PostgreSQL 15+)
-- =====================================================================
--  Modelo: B2C primero, B2B2C después.
--   · El usuario es dueño de sus datos; los gimnasios son una capa opcional.
--   · Un gimnasio solo ve datos individuales si el usuario lo autoriza
--     (tabla data_sharing_consents).
--   · "¿Tiene premium?" se resuelve en un solo lugar: private.has_premium().
--
--  Convenciones:
--   · Pesos siempre en kg y medidas en cm. La unidad que ve el usuario
--     (profiles.unit_system) se convierte en el frontend.
--   · Fechas en timestamptz (UTC); el frontend formatea a la zona local.
--   · Solo escribe el backend (service_role) en: gyms (alta), plans,
--     subscriptions, gym_subscriptions, payment_events y exercises globales.
--     service_role ignora RLS, por eso nunca va en el frontend.
--   · Pensado para ejecutarse una vez en un proyecto nuevo, como migración
--     (supabase/migrations/) o pegado en el SQL Editor.
--   · Cada tabla nueva que agregues después necesita su propio ENABLE RLS.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. SCHEMA PRIVADO Y TIPOS
-- ---------------------------------------------------------------------
-- Las funciones auxiliares viven en "private" para que PostgREST no las
-- exponga como endpoints. Las políticas RLS sí pueden llamarlas.
create schema if not exists private;
grant usage on schema private to authenticated, service_role;

create type public.unit_system          as enum ('metric', 'imperial');
create type public.exercise_owner       as enum ('global', 'user', 'gym');
create type public.gym_role             as enum ('member', 'trainer', 'admin');
create type public.membership_status    as enum ('active', 'left', 'removed');
create type public.gym_status           as enum ('active', 'suspended');
create type public.plan_audience        as enum ('user', 'gym');
create type public.billing_period       as enum ('month', 'year');
create type public.subscription_status  as enum ('trialing', 'active', 'past_due', 'canceled', 'incomplete');


-- ---------------------------------------------------------------------
-- 2. TABLAS NÚCLEO (Fase 1 · B2C)
-- ---------------------------------------------------------------------

-- 2.1 Perfil (1:1 con auth.users). Se crea solo mediante trigger (sección 5).
create table public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  display_name     text not null default '',
  avatar_url       text,
  unit_system      public.unit_system not null default 'metric',
  goal             text check (goal in ('strength', 'hypertrophy', 'fat_loss', 'endurance', 'general_health')),
  birth_date       date,
  height_cm        numeric(5,2) check (height_cm between 50 and 260),
  locale           text not null default 'es',
  onboarding_done  boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- 2.2 Gimnasios (se crea en la sección 3, pero exercises lo referencia).
create table public.gyms (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  slug           text not null unique check (slug ~ '^[a-z0-9-]+$'),
  logo_url       text,
  primary_color  text check (primary_color ~ '^#[0-9a-fA-F]{6}$'),
  status         public.gym_status not null default 'active',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- 2.3 Catálogo de ejercicios: globales (los pone el backend), de usuario o de gimnasio.
create table public.exercises (
  id             uuid primary key default gen_random_uuid(),
  owner_type     public.exercise_owner not null default 'user',
  owner_user_id  uuid references public.profiles (id) on delete cascade,
  owner_gym_id   uuid references public.gyms (id) on delete cascade,
  name           text not null check (char_length(name) between 2 and 120),
  muscle_group   text not null check (muscle_group in
                   ('chest', 'back', 'legs', 'shoulders', 'arms', 'core', 'cardio', 'full_body')),
  equipment      text not null default 'other' check (equipment in
                   ('barbell', 'dumbbell', 'machine', 'cable', 'bodyweight', 'kettlebell', 'other')),
  instructions   text,
  is_archived    boolean not null default false,   -- se archiva en vez de borrar (el historial lo referencia)
  created_at     timestamptz not null default now(),
  constraint exercises_owner_consistent check (
    (owner_type = 'global' and owner_user_id is null     and owner_gym_id is null) or
    (owner_type = 'user'   and owner_user_id is not null and owner_gym_id is null) or
    (owner_type = 'gym'    and owner_gym_id  is not null and owner_user_id is null)
  )
);

-- 2.4 Rutinas y sus ejercicios.
create table public.routines (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  name         text not null check (char_length(name) between 1 and 120),
  description  text,
  is_archived  boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.routine_exercises (
  id             uuid primary key default gen_random_uuid(),
  routine_id     uuid not null references public.routines (id) on delete cascade,
  exercise_id    uuid not null references public.exercises (id) on delete cascade,
  position       smallint not null check (position >= 0),
  target_sets    smallint check (target_sets > 0),
  target_reps    smallint check (target_reps > 0),
  target_weight_kg numeric(6,2) check (target_weight_kg >= 0),
  rest_seconds   smallint check (rest_seconds >= 0),
  notes          text,
  -- Diferida para poder intercambiar posiciones dentro de una transacción (reordenar).
  -- Consecuencia: un upsert con onConflict 'routine_id,position' NO funciona en Postgres;
  -- haz el upsert por "id" (clave primaria).
  unique (routine_id, position) deferrable initially deferred
);

-- 2.5 Entrenamientos realizados.
create table public.workout_sessions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  routine_id        uuid references public.routines (id) on delete set null,
  name              text,
  started_at        timestamptz not null default now(),
  ended_at          timestamptz,
  notes             text,
  perceived_effort  smallint check (perceived_effort between 1 and 10),
  created_at        timestamptz not null default now(),
  check (ended_at is null or ended_at >= started_at)
);

-- user_id se repite a propósito en workout_sets: es la tabla más grande y así
-- la política RLS compara una columna en vez de hacer un join por fila.
create table public.workout_sets (
  id                uuid primary key default gen_random_uuid(),
  session_id        uuid not null references public.workout_sessions (id) on delete cascade,
  user_id           uuid not null references public.profiles (id) on delete cascade,
  exercise_id       uuid not null references public.exercises (id) on delete restrict,
  set_number        smallint not null check (set_number > 0),
  reps              smallint check (reps > 0),
  weight_kg         numeric(6,2) check (weight_kg >= 0),
  duration_seconds  integer check (duration_seconds > 0),   -- plancha, cardio
  distance_m        integer check (distance_m > 0),         -- cardio
  rpe               numeric(3,1) check (rpe between 1 and 10),
  is_warmup         boolean not null default false,
  created_at        timestamptz not null default now(),
  check (reps is not null or duration_seconds is not null or distance_m is not null)
);

-- 2.6 Medidas corporales y metas.
create table public.body_measurements (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  measured_at   date not null default current_date,
  weight_kg     numeric(5,2) check (weight_kg > 0),
  body_fat_pct  numeric(4,1) check (body_fat_pct between 1 and 70),
  waist_cm      numeric(5,1) check (waist_cm > 0),
  chest_cm      numeric(5,1) check (chest_cm > 0),
  hip_cm        numeric(5,1) check (hip_cm > 0),
  arm_cm        numeric(5,1) check (arm_cm > 0),
  thigh_cm      numeric(5,1) check (thigh_cm > 0),
  notes         text,
  created_at    timestamptz not null default now()
);

create table public.goals (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  kind          text not null check (kind in ('body_weight', 'body_fat', 'exercise_weight', 'weekly_frequency')),
  exercise_id   uuid references public.exercises (id) on delete cascade,
  target_value  numeric(8,2) not null,
  target_date   date,
  achieved_at   timestamptz,
  created_at    timestamptz not null default now(),
  check ((kind = 'exercise_weight') = (exercise_id is not null))
);


-- ---------------------------------------------------------------------
-- 3. GIMNASIOS (Fase 3 · B2B2C)
-- ---------------------------------------------------------------------
create table public.gym_memberships (
  id         uuid primary key default gen_random_uuid(),
  gym_id     uuid not null references public.gyms (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  role       public.gym_role not null default 'member',
  status     public.membership_status not null default 'active',
  joined_at  timestamptz not null default now(),
  unique (gym_id, user_id)
);

create table public.gym_invites (
  id          uuid primary key default gen_random_uuid(),
  gym_id      uuid not null references public.gyms (id) on delete cascade,
  code        text not null unique check (code = upper(code) and char_length(code) between 6 and 20),
  role        public.gym_role not null default 'member' check (role <> 'admin'),  -- un código nunca crea admins
  max_uses    integer check (max_uses > 0),        -- null = ilimitado
  uses        integer not null default 0,
  expires_at  timestamptz,
  is_active   boolean not null default true,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);

-- Qué comparte cada usuario con cada gimnasio. Sin fila = no comparte nada.
create table public.data_sharing_consents (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references public.profiles (id) on delete cascade,
  gym_id              uuid not null references public.gyms (id) on delete cascade,
  share_workouts      boolean not null default false,   -- rutinas, sesiones y series
  share_measurements  boolean not null default false,   -- medidas corporales
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (user_id, gym_id)
);


-- ---------------------------------------------------------------------
-- 4. MONETIZACIÓN (Fase 2)
-- ---------------------------------------------------------------------
create table public.plans (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique,                 -- p. ej. 'user_premium_monthly'
  name               text not null,
  audience           public.plan_audience not null,        -- plan para personas o para gimnasios
  period             public.billing_period not null,
  unit_amount        integer not null check (unit_amount >= 0),  -- en la unidad mínima de la moneda
  currency           char(3) not null default 'USD',
  provider_price_id  text,                                 -- id del precio en la pasarela de pagos
  features           jsonb not null default '{}'::jsonb,   -- límites y beneficios del plan
  is_active          boolean not null default true,
  created_at         timestamptz not null default now()
);

create table public.subscriptions (
  id                        uuid primary key default gen_random_uuid(),
  user_id                   uuid not null references public.profiles (id) on delete cascade,
  plan_id                   uuid not null references public.plans (id),
  status                    public.subscription_status not null,
  provider                  text not null,                 -- 'stripe', 'mercadopago', etc.
  provider_customer_id      text,
  provider_subscription_id  text not null,
  current_period_end        timestamptz,
  cancel_at_period_end      boolean not null default false,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  unique (provider, provider_subscription_id)
);

create table public.gym_subscriptions (
  id                        uuid primary key default gen_random_uuid(),
  gym_id                    uuid not null references public.gyms (id) on delete cascade,
  plan_id                   uuid not null references public.plans (id),
  status                    public.subscription_status not null,
  seats                     integer check (seats > 0),     -- null = sin límite de miembros
  provider                  text not null,
  provider_customer_id      text,
  provider_subscription_id  text not null,
  current_period_end        timestamptz,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  unique (provider, provider_subscription_id)
);

-- Registro de webhooks. La unicidad (provider, provider_event_id) da idempotencia.
create table public.payment_events (
  id                 uuid primary key default gen_random_uuid(),
  provider           text not null,
  provider_event_id  text not null,
  event_type         text not null,
  payload            jsonb not null,
  received_at        timestamptz not null default now(),
  processed_at       timestamptz,
  error              text,
  unique (provider, provider_event_id)
);


-- ---------------------------------------------------------------------
-- 5. TRIGGERS
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['profiles', 'gyms', 'routines', 'subscriptions', 'gym_subscriptions', 'data_sharing_consents']
  loop
    execute format(
      'create trigger set_updated_at before update on public.%I
         for each row execute function public.set_updated_at()', t);
  end loop;
end $$;

-- Crea el perfil automáticamente al registrarse (email, Google, etc.).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name',
             new.raw_user_meta_data ->> 'name',
             split_part(coalesce(new.email, ''), '@', 1)),
    new.raw_user_meta_data ->> 'avatar_url'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ---------------------------------------------------------------------
-- 6. FUNCIONES AUXILIARES (permisos y entitlements)
-- ---------------------------------------------------------------------
-- SECURITY DEFINER es obligatorio aquí: si las políticas de gym_memberships
-- consultaran gym_memberships directamente, RLS entraría en recursión infinita.
-- Todas usan search_path vacío y nombres calificados (buena práctica de seguridad).

create or replace function private.has_gym_role(p_gym uuid, p_roles public.gym_role[])
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.gym_memberships m
    where m.gym_id = p_gym
      and m.user_id = (select auth.uid())
      and m.status = 'active'
      and m.role = any (p_roles)
  );
$$;

create or replace function private.is_gym_member(p_gym uuid)
returns boolean language sql stable security definer set search_path = ''
as $$ select private.has_gym_role(p_gym, array['member', 'trainer', 'admin']::public.gym_role[]); $$;

create or replace function private.is_gym_staff(p_gym uuid)
returns boolean language sql stable security definer set search_path = ''
as $$ select private.has_gym_role(p_gym, array['trainer', 'admin']::public.gym_role[]); $$;

create or replace function private.is_gym_admin(p_gym uuid)
returns boolean language sql stable security definer set search_path = ''
as $$ select private.has_gym_role(p_gym, array['admin']::public.gym_role[]); $$;

-- ¿El usuario actual es staff de un gimnasio donde "target" es miembro activo
-- Y ese miembro autorizó compartir este tipo de dato?  kind: 'workouts' | 'measurements'
create or replace function private.staff_can_view(target uuid, kind text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.gym_memberships staff
    join public.gyms g              on g.id = staff.gym_id and g.status = 'active'
    join public.gym_memberships mem on mem.gym_id = staff.gym_id
    join public.data_sharing_consents c on c.user_id = mem.user_id and c.gym_id = staff.gym_id
    where staff.user_id = (select auth.uid())
      and staff.status = 'active'
      and staff.role in ('trainer', 'admin')
      and mem.user_id = target
      and mem.status = 'active'
      and case kind
            when 'workouts'     then c.share_workouts
            when 'measurements' then c.share_measurements
            else false
          end
  );
$$;

-- Entitlement único: premium propio O por tener un gimnasio con plan activo.
-- Úsalo desde el backend (service_role) o desde RLS; el frontend usa me_has_premium().
create or replace function private.has_premium(uid uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select
    exists (
      select 1 from public.subscriptions s
      where s.user_id = uid and s.status in ('active', 'trialing')
    )
    or exists (
      select 1
      from public.gym_memberships m
      join public.gyms g               on g.id = m.gym_id and g.status = 'active'
      join public.gym_subscriptions gs on gs.gym_id = m.gym_id and gs.status in ('active', 'trialing')
      where m.user_id = uid and m.status = 'active'
    );
$$;

-- Versión para el frontend: solo responde por el usuario autenticado.
create or replace function public.me_has_premium()
returns boolean
language sql stable set search_path = ''
as $$ select private.has_premium((select auth.uid())); $$;

revoke execute on function public.me_has_premium() from public, anon;
grant  execute on function public.me_has_premium() to authenticated;

-- Unirse a un gimnasio con código/QR. Atómico: valida, crea la membresía y
-- cuenta el uso. Devuelve el gym_id. Errores: invalid_invite, removed_from_gym.
create or replace function public.join_gym_with_code(p_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_invite  public.gym_invites;
  v_status  public.membership_status;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  select i.* into v_invite
  from public.gym_invites i
  join public.gyms g on g.id = i.gym_id and g.status = 'active'
  where i.code = upper(trim(p_code))
    and i.is_active
    and (i.expires_at is null or i.expires_at > now())
    and (i.max_uses   is null or i.uses < i.max_uses)
  for update of i;

  if not found then
    raise exception 'invalid_invite' using errcode = 'P0002';
  end if;

  select m.status into v_status
  from public.gym_memberships m
  where m.gym_id = v_invite.gym_id and m.user_id = v_uid;

  if v_status = 'active' then
    return v_invite.gym_id;                       -- ya es miembro: no gasta el código
  end if;
  if v_status = 'removed' then
    raise exception 'removed_from_gym' using errcode = '42501';
  end if;

  insert into public.gym_memberships (gym_id, user_id, role, status)
  values (v_invite.gym_id, v_uid, v_invite.role, 'active')
  on conflict (gym_id, user_id)
  do update set status = 'active', joined_at = now();   -- reingreso tras 'left'

  update public.gym_invites set uses = uses + 1 where id = v_invite.id;

  return v_invite.gym_id;
end;
$$;

revoke execute on function public.join_gym_with_code(text) from public, anon;
grant  execute on function public.join_gym_with_code(text) to authenticated;


-- ---------------------------------------------------------------------
-- 7. ÍNDICES (incluye las claves foráneas que se consultan a menudo)
-- ---------------------------------------------------------------------
create unique index exercises_global_name_uq on public.exercises (lower(name)) where owner_type = 'global';
create index exercises_owner_user_idx   on public.exercises (owner_user_id) where owner_user_id is not null;
create index exercises_owner_gym_idx    on public.exercises (owner_gym_id)  where owner_gym_id  is not null;

create index routines_user_idx          on public.routines (user_id);
create index routine_exercises_exercise_idx on public.routine_exercises (exercise_id);

create index workout_sessions_user_started_idx on public.workout_sessions (user_id, started_at desc);
create index workout_sessions_routine_idx      on public.workout_sessions (routine_id) where routine_id is not null;
create index workout_sets_session_idx          on public.workout_sets (session_id);
create index workout_sets_user_exercise_idx    on public.workout_sets (user_id, exercise_id);
create index workout_sets_exercise_idx         on public.workout_sets (exercise_id);

create index body_measurements_user_date_idx   on public.body_measurements (user_id, measured_at desc);
create index goals_user_idx                    on public.goals (user_id);

create index gym_memberships_user_idx          on public.gym_memberships (user_id);
create index gym_memberships_gym_status_idx    on public.gym_memberships (gym_id, status);
create index gym_invites_gym_idx               on public.gym_invites (gym_id);
create index data_sharing_consents_gym_idx     on public.data_sharing_consents (gym_id);

create index subscriptions_user_idx            on public.subscriptions (user_id);
create index subscriptions_plan_idx            on public.subscriptions (plan_id);
create index gym_subscriptions_gym_idx         on public.gym_subscriptions (gym_id);
create index gym_subscriptions_plan_idx        on public.gym_subscriptions (plan_id);


-- ---------------------------------------------------------------------
-- 8. ROW LEVEL SECURITY: activarlo en TODAS las tablas de public
-- ---------------------------------------------------------------------
-- Con RLS activo y sin política, nadie (salvo service_role) puede leer ni
-- escribir. Por eso payment_events no tiene políticas: es solo del backend.
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', r.tablename);
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- 9. POLÍTICAS
-- ---------------------------------------------------------------------
-- Nota de rendimiento: (select auth.uid()) en vez de auth.uid() hace que
-- Postgres evalúe la función una vez por consulta y no una vez por fila.

-- 9.1 profiles ------------------------------------------------------
-- Solo el propio usuario. Los gimnasios verán nombre/foto de sus miembros
-- mediante una función RPC en la Fase 3, para no exponer birth_date, etc.
create policy profiles_select_own on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy profiles_insert_own on public.profiles
  for insert to authenticated with check (id = (select auth.uid()));
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- 9.2 exercises -----------------------------------------------------
create policy exercises_select on public.exercises
  for select to authenticated
  using (
    owner_type = 'global'
    or owner_user_id = (select auth.uid())
    or (owner_type = 'gym' and private.is_gym_member(owner_gym_id))
  );
create policy exercises_insert on public.exercises
  for insert to authenticated
  with check (
    (owner_type = 'user' and owner_user_id = (select auth.uid()))
    or (owner_type = 'gym' and private.is_gym_staff(owner_gym_id))
  );
create policy exercises_update on public.exercises
  for update to authenticated
  using (
    (owner_type = 'user' and owner_user_id = (select auth.uid()))
    or (owner_type = 'gym' and private.is_gym_staff(owner_gym_id))
  )
  with check (
    (owner_type = 'user' and owner_user_id = (select auth.uid()))
    or (owner_type = 'gym' and private.is_gym_staff(owner_gym_id))
  );
create policy exercises_delete on public.exercises
  for delete to authenticated
  using (
    (owner_type = 'user' and owner_user_id = (select auth.uid()))
    or (owner_type = 'gym' and private.is_gym_staff(owner_gym_id))
  );

-- 9.3 routines y routine_exercises ---------------------------------
create policy routines_own on public.routines
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy routines_staff_select on public.routines
  for select to authenticated
  using (private.staff_can_view(user_id, 'workouts'));

create policy routine_exercises_own on public.routine_exercises
  for all to authenticated
  using (exists (select 1 from public.routines r
                 where r.id = routine_exercises.routine_id and r.user_id = (select auth.uid())))
  with check (exists (select 1 from public.routines r
                      where r.id = routine_exercises.routine_id and r.user_id = (select auth.uid())));
create policy routine_exercises_staff_select on public.routine_exercises
  for select to authenticated
  using (exists (select 1 from public.routines r
                 where r.id = routine_exercises.routine_id
                   and private.staff_can_view(r.user_id, 'workouts')));

-- 9.4 workout_sessions y workout_sets ------------------------------
create policy workout_sessions_own on public.workout_sessions
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy workout_sessions_staff_select on public.workout_sessions
  for select to authenticated
  using (private.staff_can_view(user_id, 'workouts'));

create policy workout_sets_own on public.workout_sets
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.workout_sessions s
                where s.id = workout_sets.session_id and s.user_id = (select auth.uid()))
  );
create policy workout_sets_staff_select on public.workout_sets
  for select to authenticated
  using (private.staff_can_view(user_id, 'workouts'));

-- 9.5 body_measurements y goals ------------------------------------
create policy body_measurements_own on public.body_measurements
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy body_measurements_staff_select on public.body_measurements
  for select to authenticated
  using (private.staff_can_view(user_id, 'measurements'));

create policy goals_own on public.goals
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- 9.6 gyms ----------------------------------------------------------
-- El alta de gimnasios la hace el backend (service_role). Los miembros leen
-- su gimnasio y solo los admins editan la marca.
create policy gyms_select_members on public.gyms
  for select to authenticated using (private.is_gym_member(id));
create policy gyms_update_admin on public.gyms
  for update to authenticated
  using (private.is_gym_admin(id)) with check (private.is_gym_admin(id));

-- Un admin solo puede tocar la marca, no el estado ni el slug.
revoke update on public.gyms from authenticated;
grant  update (name, logo_url, primary_color) on public.gyms to authenticated;

-- 9.7 gym_memberships ----------------------------------------------
-- Sin política de INSERT: se entra solo con join_gym_with_code() o desde el backend.
create policy memberships_select on public.gym_memberships
  for select to authenticated
  using (user_id = (select auth.uid()) or private.is_gym_staff(gym_id));
create policy memberships_update_admin on public.gym_memberships
  for update to authenticated
  using (private.is_gym_admin(gym_id)) with check (private.is_gym_admin(gym_id));
-- Salir del gimnasio. Solo si está activo, para que un 'removed' no pueda
-- borrar su fila y volver a entrar con un código.
create policy memberships_leave on public.gym_memberships
  for delete to authenticated
  using (user_id = (select auth.uid()) and status = 'active');

revoke update on public.gym_memberships from authenticated;
grant  update (role, status) on public.gym_memberships to authenticated;

-- 9.8 gym_invites ---------------------------------------------------
create policy gym_invites_admin on public.gym_invites
  for all to authenticated
  using (private.is_gym_admin(gym_id))
  with check (private.is_gym_admin(gym_id));

-- 9.9 data_sharing_consents ----------------------------------------
-- Solo el usuario decide, y solo para gimnasios donde es miembro activo.
create policy consents_own on public.data_sharing_consents
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and private.is_gym_member(gym_id));

-- 9.10 Monetización -------------------------------------------------
-- Planes: públicos (la página de precios los muestra aun sin sesión).
create policy plans_select_active on public.plans
  for select to anon, authenticated using (is_active);

-- Suscripciones: el usuario ve las suyas; solo el backend escribe (webhooks).
create policy subscriptions_select_own on public.subscriptions
  for select to authenticated using (user_id = (select auth.uid()));

-- Suscripción del gimnasio: solo sus admins la ven.
create policy gym_subscriptions_select_admin on public.gym_subscriptions
  for select to authenticated using (private.is_gym_admin(gym_id));

-- payment_events: sin políticas a propósito.


-- ---------------------------------------------------------------------
-- 10. VISTA PARA GRÁFICOS DE PROGRESO
-- ---------------------------------------------------------------------
-- security_invoker = la vista respeta el RLS de quien la consulta.
-- (Sin esto, una vista en Postgres corre con los permisos de su dueño y se salta RLS.)
-- 1RM estimado con la fórmula de Epley: peso * (1 + reps / 30).
create view public.exercise_progress
with (security_invoker = true) as
select
  s.user_id,
  s.exercise_id,
  wo.id                                   as session_id,
  wo.started_at                           as performed_at,
  max(s.weight_kg)                        as max_weight_kg,
  sum(s.weight_kg * s.reps)               as volume_kg,
  max(s.weight_kg * (1 + s.reps / 30.0))  as est_1rm_kg
from public.workout_sets s
join public.workout_sessions wo on wo.id = s.session_id
where not s.is_warmup
  and s.weight_kg is not null
  and s.reps is not null
group by s.user_id, s.exercise_id, wo.id, wo.started_at;

grant select on public.exercise_progress to authenticated;


-- ---------------------------------------------------------------------
-- 11. DATOS INICIALES: catálogo global de ejercicios
-- ---------------------------------------------------------------------
insert into public.exercises (owner_type, name, muscle_group, equipment) values
  ('global', 'Press de banca con barra',        'chest',     'barbell'),
  ('global', 'Press inclinado con mancuernas',  'chest',     'dumbbell'),
  ('global', 'Aperturas en polea',              'chest',     'cable'),
  ('global', 'Flexiones',                       'chest',     'bodyweight'),
  ('global', 'Dominadas',                       'back',      'bodyweight'),
  ('global', 'Remo con barra',                  'back',      'barbell'),
  ('global', 'Remo con mancuerna',              'back',      'dumbbell'),
  ('global', 'Jalón al pecho',                  'back',      'cable'),
  ('global', 'Peso muerto',                     'back',      'barbell'),
  ('global', 'Sentadilla con barra',            'legs',      'barbell'),
  ('global', 'Prensa de piernas',               'legs',      'machine'),
  ('global', 'Peso muerto rumano',              'legs',      'barbell'),
  ('global', 'Zancadas con mancuernas',         'legs',      'dumbbell'),
  ('global', 'Curl femoral',                    'legs',      'machine'),
  ('global', 'Extensión de cuádriceps',         'legs',      'machine'),
  ('global', 'Elevación de talones',            'legs',      'machine'),
  ('global', 'Press militar con barra',         'shoulders', 'barbell'),
  ('global', 'Elevaciones laterales',           'shoulders', 'dumbbell'),
  ('global', 'Pájaros con mancuernas',          'shoulders', 'dumbbell'),
  ('global', 'Curl con barra',                  'arms',      'barbell'),
  ('global', 'Curl martillo',                   'arms',      'dumbbell'),
  ('global', 'Extensión de tríceps en polea',   'arms',      'cable'),
  ('global', 'Fondos en paralelas',             'arms',      'bodyweight'),
  ('global', 'Plancha',                         'core',      'bodyweight'),
  ('global', 'Crunch abdominal',                'core',      'bodyweight'),
  ('global', 'Elevación de piernas colgado',    'core',      'bodyweight'),
  ('global', 'Cinta de correr',                 'cardio',    'machine'),
  ('global', 'Bicicleta estática',              'cardio',    'machine'),
  ('global', 'Remo en ergómetro',               'cardio',    'machine')
on conflict do nothing;