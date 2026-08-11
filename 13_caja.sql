-- =====================================================
-- DRITO - MÓDULO DE CAJA
-- INGRESOS, EGRESOS Y MOVIMIENTOS FINANCIEROS
-- =====================================================

-- =====================================================
-- CATEGORÍAS DE CAJA
-- =====================================================

create table if not exists public.categorias_caja (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,

  nombre text not null
    check (
      char_length(trim(nombre)) >= 2
    ),

  tipo text not null
    check (
      tipo in (
        'ingreso',
        'egreso',
        'ambos'
      )
    ),

  sistema boolean not null default false,

  activo boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (
    comercio_id,
    nombre
  )
);

-- =====================================================
-- MOVIMIENTOS DE CAJA
-- =====================================================

create table if not exists public.movimientos_caja (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,

  categoria_id uuid
    references public.categorias_caja(id)
    on delete set null,

  tipo text not null
    check (
      tipo in (
        'ingreso',
        'egreso'
      )
    ),

  origen text not null default 'manual'
    check (
      origen in (
        'manual',
        'venta',
        'compra',
        'ajuste',
        'apertura',
        'cierre'
      )
    ),

  fecha date not null default current_date,

  importe numeric(14,2) not null
    check (importe > 0),

  medio_pago text not null default 'efectivo'
    check (
      medio_pago in (
        'efectivo',
        'transferencia',
        'tarjeta_debito',
        'tarjeta_credito',
        'billetera_virtual',
        'cheque',
        'deposito',
        'otro'
      )
    ),

  concepto text not null
    check (
      char_length(trim(concepto)) >= 2
    ),

  referencia text,
  observaciones text,

  referencia_tipo text,
  referencia_id uuid,

  estado text not null default 'registrado'
    check (
      estado in (
        'registrado',
        'anulado'
      )
    ),

  creado_por uuid
    references auth.users(id)
    on delete set null
    default auth.uid(),

  anulado_at timestamptz,

  anulado_por uuid
    references auth.users(id)
    on delete set null,

  motivo_anulacion text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (
    (
      estado = 'registrado'
      and anulado_at is null
      and motivo_anulacion is null
    )
    or
    (
      estado = 'anulado'
      and anulado_at is not null
      and motivo_anulacion is not null
    )
  )
);

-- =====================================================
-- ÍNDICES
-- =====================================================

create index if not exists
categorias_caja_comercio_idx
on public.categorias_caja (
  comercio_id,
  activo
);

create index if not exists
movimientos_caja_comercio_fecha_idx
on public.movimientos_caja (
  comercio_id,
  fecha desc,
  created_at desc
);

create index if not exists
movimientos_caja_tipo_idx
on public.movimientos_caja (
  comercio_id,
  tipo
);

create index if not exists
movimientos_caja_origen_idx
on public.movimientos_caja (
  comercio_id,
  origen
);

create index if not exists
movimientos_caja_medio_pago_idx
on public.movimientos_caja (
  comercio_id,
  medio_pago
);

create index if not exists
movimientos_caja_referencia_idx
on public.movimientos_caja (
  referencia_tipo,
  referencia_id
);

create unique index if not exists
movimientos_caja_referencia_unica_idx
on public.movimientos_caja (
  comercio_id,
  referencia_tipo,
  referencia_id
)
where referencia_id is not null;

-- =====================================================
-- UPDATED_AT
-- =====================================================

create or replace function
public.actualizar_categorias_caja_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();

  return new;
end;
$$;

drop trigger if exists
categorias_caja_updated_at
on public.categorias_caja;

create trigger
categorias_caja_updated_at
before update
on public.categorias_caja
for each row
execute function
public.actualizar_categorias_caja_updated_at();

create or replace function
public.actualizar_movimientos_caja_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();

  return new;
end;
$$;

drop trigger if exists
movimientos_caja_updated_at
on public.movimientos_caja;

create trigger
movimientos_caja_updated_at
before update
on public.movimientos_caja
for each row
execute function
public.actualizar_movimientos_caja_updated_at();

-- =====================================================
-- ROW LEVEL SECURITY
-- =====================================================

alter table public.categorias_caja
enable row level security;

alter table public.movimientos_caja
enable row level security;

-- =====================================================
-- POLÍTICAS DE CATEGORÍAS
-- =====================================================

drop policy if exists
"Miembros pueden ver categorias de caja"
on public.categorias_caja;

create policy
"Miembros pueden ver categorias de caja"
on public.categorias_caja
for select
to authenticated
using (
  public.pertenece_a_comercio(
    comercio_id
  )
);

drop policy if exists
"Miembros pueden crear categorias de caja"
on public.categorias_caja;

create policy
"Miembros pueden crear categorias de caja"
on public.categorias_caja
for insert
to authenticated
with check (
  public.pertenece_a_comercio(
    comercio_id
  )
);

drop policy if exists
"Miembros pueden actualizar categorias de caja"
on public.categorias_caja;

create policy
"Miembros pueden actualizar categorias de caja"
on public.categorias_caja
for update
to authenticated
using (
  public.pertenece_a_comercio(
    comercio_id
  )
)
with check (
  public.pertenece_a_comercio(
    comercio_id
  )
);

-- =====================================================
-- POLÍTICAS DE MOVIMIENTOS
-- =====================================================

drop policy if exists
"Miembros pueden ver movimientos de caja"
on public.movimientos_caja;

create policy
"Miembros pueden ver movimientos de caja"
on public.movimientos_caja
for select
to authenticated
using (
  public.pertenece_a_comercio(
    comercio_id
  )
);

-- Las escrituras se realizan únicamente mediante
-- funciones controladas.

-- =====================================================
-- CREAR CATEGORÍAS PREDETERMINADAS
-- =====================================================

create or replace function
public.crear_categorias_caja_predeterminadas(
  p_comercio_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;

  if not public.pertenece_a_comercio(
    p_comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio';
  end if;

  insert into public.categorias_caja (
    comercio_id,
    nombre,
    tipo,
    sistema,
    activo
  )
  values
    (
      p_comercio_id,
      'Cobro de venta',
      'ingreso',
      true,
      true
    ),
    (
      p_comercio_id,
      'Pago a proveedor',
      'egreso',
      true,
      true
    ),
    (
      p_comercio_id,
      'Otros ingresos',
      'ingreso',
      true,
      true
    ),
    (
      p_comercio_id,
      'Servicios',
      'egreso',
      true,
      true
    ),
    (
      p_comercio_id,
      'Alquiler',
      'egreso',
      true,
      true
    ),
    (
      p_comercio_id,
      'Impuestos',
      'egreso',
      true,
      true
    ),
    (
      p_comercio_id,
      'Sueldos',
      'egreso',
      true,
      true
    ),
    (
      p_comercio_id,
      'Otros egresos',
      'egreso',
      true,
      true
    )
  on conflict (
    comercio_id,
    nombre
  )
  do nothing;
end;
$$;

-- =====================================================
-- REGISTRAR MOVIMIENTO MANUAL
-- =====================================================

create or replace function
public.registrar_movimiento_caja(
  p_comercio_id uuid,
  p_categoria_id uuid,
  p_tipo text,
  p_fecha date,
  p_importe numeric,
  p_medio_pago text,
  p_concepto text,
  p_referencia text,
  p_observaciones text
)
returns table (
  movimiento_id uuid,
  tipo_movimiento text,
  importe_movimiento numeric,
  fecha_movimiento date
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_categoria_comercio_id uuid;
  v_categoria_tipo text;
  v_categoria_activa boolean;

  v_tipo text;
  v_medio_pago text;
  v_concepto text;
  v_importe numeric(14,2);

  v_movimiento_id uuid;
begin
  -- ===================================================
  -- AUTENTICACIÓN
  -- ===================================================

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;

  if p_comercio_id is null then
    raise exception
      'El comercio es obligatorio';
  end if;

  if not public.pertenece_a_comercio(
    p_comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio';
  end if;

  -- ===================================================
  -- TIPO
  -- ===================================================

  v_tipo :=
    lower(
      trim(
        coalesce(
          p_tipo,
          ''
        )
      )
    );

  if v_tipo not in (
    'ingreso',
    'egreso'
  ) then
    raise exception
      'El tipo de movimiento es inválido';
  end if;

  -- ===================================================
  -- FECHA
  -- ===================================================

  if p_fecha is null then
    raise exception
      'La fecha es obligatoria';
  end if;

  if p_fecha > current_date then
    raise exception
      'La fecha no puede ser futura';
  end if;

  -- ===================================================
  -- IMPORTE
  -- ===================================================

  v_importe :=
    round(
      coalesce(
        p_importe,
        0
      ),
      2
    );

  if v_importe <= 0 then
    raise exception
      'El importe debe ser mayor que cero';
  end if;

  -- ===================================================
  -- CATEGORÍA
  -- ===================================================

  if p_categoria_id is null then
    raise exception
      'La categoría es obligatoria';
  end if;

  select
    cc.comercio_id,
    cc.tipo,
    cc.activo
  into
    v_categoria_comercio_id,
    v_categoria_tipo,
    v_categoria_activa
  from public.categorias_caja as cc
  where cc.id = p_categoria_id;

  if not found then
    raise exception
      'Categoría no encontrada';
  end if;

  if v_categoria_comercio_id <> p_comercio_id then
    raise exception
      'La categoría pertenece a otro comercio';
  end if;

  if v_categoria_activa = false then
    raise exception
      'La categoría se encuentra inactiva';
  end if;

  if (
    v_categoria_tipo <> 'ambos'
    and v_categoria_tipo <> v_tipo
  ) then
    raise exception
      'La categoría no corresponde al tipo de movimiento';
  end if;

  -- ===================================================
  -- MEDIO DE PAGO
  -- ===================================================

  v_medio_pago :=
    lower(
      trim(
        coalesce(
          p_medio_pago,
          'efectivo'
        )
      )
    );

  if v_medio_pago not in (
    'efectivo',
    'transferencia',
    'tarjeta_debito',
    'tarjeta_credito',
    'billetera_virtual',
    'cheque',
    'deposito',
    'otro'
  ) then
    raise exception
      'El medio de pago es inválido';
  end if;

  -- ===================================================
  -- CONCEPTO
  -- ===================================================

  v_concepto :=
    trim(
      coalesce(
        p_concepto,
        ''
      )
    );

  if char_length(v_concepto) < 2 then
    raise exception
      'El concepto debe tener al menos 2 caracteres';
  end if;

  if char_length(v_concepto) > 150 then
    raise exception
      'El concepto no puede superar los 150 caracteres';
  end if;

  -- ===================================================
  -- REGISTRAR MOVIMIENTO
  -- ===================================================

  insert into public.movimientos_caja (
    comercio_id,
    categoria_id,
    tipo,
    origen,
    fecha,
    importe,
    medio_pago,
    concepto,
    referencia,
    observaciones,
    estado,
    creado_por
  )
  values (
    p_comercio_id,
    p_categoria_id,
    v_tipo,
    'manual',
    p_fecha,
    v_importe,
    v_medio_pago,
    v_concepto,

    nullif(
      trim(
        coalesce(
          p_referencia,
          ''
        )
      ),
      ''
    ),

    nullif(
      trim(
        coalesce(
          p_observaciones,
          ''
        )
      ),
      ''
    ),

    'registrado',
    auth.uid()
  )
  returning id
  into v_movimiento_id;

  return query
  select
    v_movimiento_id,
    v_tipo,
    v_importe,
    p_fecha;
end;
$$;

-- =====================================================
-- ANULAR MOVIMIENTO MANUAL
-- =====================================================

create or replace function
public.anular_movimiento_caja(
  p_movimiento_id uuid,
  p_motivo text
)
returns table (
  movimiento_id uuid,
  tipo_movimiento text,
  importe_movimiento numeric,
  estado_movimiento text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comercio_id uuid;
  v_tipo text;
  v_importe numeric(14,2);
  v_origen text;
  v_estado text;

  v_motivo text;
begin
  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;

  if p_movimiento_id is null then
    raise exception
      'El movimiento es obligatorio';
  end if;

  select
    mc.comercio_id,
    mc.tipo,
    mc.importe,
    mc.origen,
    mc.estado
  into
    v_comercio_id,
    v_tipo,
    v_importe,
    v_origen,
    v_estado
  from public.movimientos_caja as mc
  where mc.id = p_movimiento_id
  for update;

  if not found then
    raise exception
      'Movimiento no encontrado';
  end if;

  if not public.pertenece_a_comercio(
    v_comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio';
  end if;

  if v_origen <> 'manual' then
    raise exception
      'Los movimientos automáticos deben anularse desde su operación de origen';
  end if;

  if v_estado = 'anulado' then
    raise exception
      'El movimiento ya se encuentra anulado';
  end if;

  v_motivo :=
    trim(
      coalesce(
        p_motivo,
        ''
      )
    );

  if char_length(v_motivo) < 3 then
    raise exception
      'El motivo debe tener al menos 3 caracteres';
  end if;

  if char_length(v_motivo) > 250 then
    raise exception
      'El motivo no puede superar los 250 caracteres';
  end if;

  update public.movimientos_caja
  set
    estado = 'anulado',
    anulado_at = now(),
    anulado_por = auth.uid(),
    motivo_anulacion = v_motivo
  where id = p_movimiento_id;

  return query
  select
    p_movimiento_id,
    v_tipo,
    v_importe,
    'anulado'::text;
end;
$$;

-- =====================================================
-- RESUMEN DE CAJA
-- =====================================================

create or replace function
public.obtener_resumen_caja(
  p_comercio_id uuid,
  p_fecha_desde date,
  p_fecha_hasta date
)
returns table (
  total_ingresos numeric,
  total_egresos numeric,
  saldo numeric,
  movimientos_registrados bigint
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;

  if not public.pertenece_a_comercio(
    p_comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio';
  end if;

  if p_fecha_desde is null then
    raise exception
      'La fecha desde es obligatoria';
  end if;

  if p_fecha_hasta is null then
    raise exception
      'La fecha hasta es obligatoria';
  end if;

  if p_fecha_hasta < p_fecha_desde then
    raise exception
      'La fecha hasta no puede ser anterior a la fecha desde';
  end if;

  return query
  select
    coalesce(
      sum(mc.importe)
      filter (
        where mc.tipo = 'ingreso'
      ),
      0
    )::numeric,

    coalesce(
      sum(mc.importe)
      filter (
        where mc.tipo = 'egreso'
      ),
      0
    )::numeric,

    (
      coalesce(
        sum(mc.importe)
        filter (
          where mc.tipo = 'ingreso'
        ),
        0
      )
      -
      coalesce(
        sum(mc.importe)
        filter (
          where mc.tipo = 'egreso'
        ),
        0
      )
    )::numeric,

    count(*)::bigint

  from public.movimientos_caja as mc

  where mc.comercio_id = p_comercio_id
    and mc.estado = 'registrado'
    and mc.fecha between
      p_fecha_desde
      and p_fecha_hasta;
end;
$$;

-- =====================================================
-- PERMISOS DE TABLAS
-- =====================================================

revoke all
on public.categorias_caja
from anon;

revoke all
on public.movimientos_caja
from anon;

grant select, insert, update
on public.categorias_caja
to authenticated;

grant select
on public.movimientos_caja
to authenticated;

-- =====================================================
-- PERMISOS DE FUNCIONES
-- =====================================================

revoke all
on function
public.crear_categorias_caja_predeterminadas(
  uuid
)
from public;

grant execute
on function
public.crear_categorias_caja_predeterminadas(
  uuid
)
to authenticated;

revoke all
on function
public.registrar_movimiento_caja(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  text
)
from public;

grant execute
on function
public.registrar_movimiento_caja(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  text
)
to authenticated;

revoke all
on function
public.anular_movimiento_caja(
  uuid,
  text
)
from public;

grant execute
on function
public.anular_movimiento_caja(
  uuid,
  text
)
to authenticated;

revoke all
on function
public.obtener_resumen_caja(
  uuid,
  date,
  date
)
from public;

grant execute
on function
public.obtener_resumen_caja(
  uuid,
  date,
  date
)
to authenticated;