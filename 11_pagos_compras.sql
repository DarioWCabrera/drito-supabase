-- =====================================================
-- DRITO - PAGOS DE COMPRAS
-- PAGOS A PROVEEDORES
-- =====================================================

-- =====================================================
-- CONTADOR DE PAGOS DE COMPRAS
-- =====================================================

create table if not exists
public.pago_compra_contadores (
  comercio_id uuid primary key
    references public.comercios(id)
    on delete cascade,

  ultimo_numero bigint not null default 0
    check (ultimo_numero >= 0),

  updated_at timestamptz not null default now()
);

-- =====================================================
-- PAGOS DE COMPRAS
-- =====================================================

create table if not exists
public.pagos_compras (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,

  compra_id uuid not null
    references public.compras(id)
    on delete cascade,

  proveedor_id uuid not null
    references public.proveedores(id)
    on delete restrict,

  numero bigint not null
    check (numero > 0),

  fecha_pago date not null default current_date,

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

  referencia text,
  observaciones text,

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

  unique (
    comercio_id,
    numero
  )
);

-- =====================================================
-- ÍNDICES
-- =====================================================

create index if not exists
pagos_compras_comercio_fecha_idx
on public.pagos_compras (
  comercio_id,
  fecha_pago desc
);

create index if not exists
pagos_compras_compra_idx
on public.pagos_compras (
  compra_id,
  fecha_pago desc
);

create index if not exists
pagos_compras_proveedor_idx
on public.pagos_compras (
  proveedor_id,
  fecha_pago desc
);

create index if not exists
pagos_compras_estado_idx
on public.pagos_compras (
  comercio_id,
  estado
);

-- =====================================================
-- UPDATED_AT
-- =====================================================

create or replace function
public.actualizar_pagos_compras_updated_at()
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
pagos_compras_updated_at
on public.pagos_compras;

create trigger
pagos_compras_updated_at
before update
on public.pagos_compras
for each row
execute function
public.actualizar_pagos_compras_updated_at();

-- =====================================================
-- ROW LEVEL SECURITY
-- =====================================================

alter table public.pago_compra_contadores
enable row level security;

alter table public.pagos_compras
enable row level security;

-- =====================================================
-- POLÍTICAS DE LECTURA
-- =====================================================

drop policy if exists
"Miembros pueden ver contadores de pagos de compras"
on public.pago_compra_contadores;

create policy
"Miembros pueden ver contadores de pagos de compras"
on public.pago_compra_contadores
for select
to authenticated
using (
  public.pertenece_a_comercio(
    comercio_id
  )
);

drop policy if exists
"Miembros pueden ver pagos de compras"
on public.pagos_compras;

create policy
"Miembros pueden ver pagos de compras"
on public.pagos_compras
for select
to authenticated
using (
  public.pertenece_a_comercio(
    comercio_id
  )
);

-- Las inserciones y modificaciones se realizan
-- únicamente mediante funciones transaccionales.

-- =====================================================
-- REGISTRAR PAGO DE COMPRA
-- =====================================================

create or replace function
public.registrar_pago_compra(
  p_compra_id uuid,
  p_importe numeric,
  p_fecha_pago date,
  p_medio_pago text,
  p_referencia text,
  p_observaciones text
)
returns table (
  pago_id uuid,
  numero_pago bigint,
  total_pagado numeric,
  saldo_pendiente numeric,
  estado_pago text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comercio_id uuid;
  v_proveedor_id uuid;

  v_numero_compra bigint;
  v_estado_compra text;

  v_fecha_compra date;

  v_total_compra numeric(14,2);
  v_total_pagado_actual numeric(14,2);

  v_importe numeric(14,2);
  v_saldo_anterior numeric(14,2);

  v_nuevo_total_pagado numeric(14,2);
  v_nuevo_saldo_pendiente numeric(14,2);
  v_nuevo_estado_pago text;

  v_medio_pago text;

  v_pago_id uuid;
  v_numero_pago bigint;
begin
  -- ===================================================
  -- AUTENTICACIÓN
  -- ===================================================

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;

  if p_compra_id is null then
    raise exception
      'La compra es obligatoria';
  end if;

  -- Bloqueamos la compra para evitar que dos pagos
  -- simultáneos superen el saldo disponible.

  select
    c.comercio_id,
    c.proveedor_id,
    c.numero,
    c.estado,
    c.fecha_compra,
    c.total,
    c.total_pagado
  into
    v_comercio_id,
    v_proveedor_id,
    v_numero_compra,
    v_estado_compra,
    v_fecha_compra,
    v_total_compra,
    v_total_pagado_actual
  from public.compras as c
  where c.id = p_compra_id
  for update;

  if not found then
    raise exception
      'Compra no encontrada';
  end if;

  if not public.pertenece_a_comercio(
    v_comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio de la compra';
  end if;

  if v_estado_compra <> 'confirmada' then
    raise exception
      'La compra no admite nuevos pagos';
  end if;

  -- ===================================================
  -- FECHA
  -- ===================================================

  if p_fecha_pago is null then
    raise exception
      'La fecha de pago es obligatoria';
  end if;

  if p_fecha_pago > current_date then
    raise exception
      'La fecha de pago no puede ser futura';
  end if;

  if p_fecha_pago < v_fecha_compra then
    raise exception
      'La fecha de pago no puede ser anterior a la compra';
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

  v_saldo_anterior :=
    greatest(
      v_total_compra
      - v_total_pagado_actual,
      0
    );

  if v_saldo_anterior <= 0 then
    raise exception
      'La compra ya se encuentra totalmente pagada';
  end if;

  if v_importe > v_saldo_anterior then
    raise exception
      'El importe supera el saldo pendiente. Saldo disponible: %',
      v_saldo_anterior;
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
  -- GENERAR NÚMERO DE PAGO
  -- ===================================================

  insert into public.pago_compra_contadores (
    comercio_id,
    ultimo_numero,
    updated_at
  )
  values (
    v_comercio_id,
    1,
    now()
  )
  on conflict (comercio_id)
  do update set
    ultimo_numero =
      public.pago_compra_contadores.ultimo_numero + 1,

    updated_at = now()

  returning ultimo_numero
  into v_numero_pago;

  -- ===================================================
  -- REGISTRAR PAGO
  -- ===================================================

  insert into public.pagos_compras (
    comercio_id,
    compra_id,
    proveedor_id,
    numero,
    fecha_pago,
    importe,
    medio_pago,
    referencia,
    observaciones,
    estado,
    creado_por
  )
  values (
    v_comercio_id,
    p_compra_id,
    v_proveedor_id,
    v_numero_pago,
    p_fecha_pago,
    v_importe,
    v_medio_pago,

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
  into v_pago_id;

  -- ===================================================
  -- ACTUALIZAR COMPRA
  -- ===================================================

  v_nuevo_total_pagado :=
    round(
      v_total_pagado_actual
      + v_importe,
      2
    );

  v_nuevo_saldo_pendiente :=
    greatest(
      v_total_compra
      - v_nuevo_total_pagado,
      0
    );

  if v_nuevo_saldo_pendiente = 0 then
    v_nuevo_estado_pago := 'pagada';
  else
    v_nuevo_estado_pago := 'parcial';
  end if;

  update public.compras as c
  set
    total_pagado =
      v_nuevo_total_pagado,

    estado_pago =
      v_nuevo_estado_pago
  where c.id = p_compra_id;

  -- ===================================================
  -- RESULTADO
  -- ===================================================

  return query
  select
    v_pago_id,
    v_numero_pago,
    v_nuevo_total_pagado,
    v_nuevo_saldo_pendiente,
    v_nuevo_estado_pago;
end;
$$;

-- =====================================================
-- ANULAR PAGO DE COMPRA
-- =====================================================

create or replace function
public.anular_pago_compra(
  p_pago_id uuid,
  p_motivo text
)
returns table (
  pago_id uuid,
  compra_id uuid,
  numero_pago bigint,
  importe_anulado numeric,
  total_pagado numeric,
  saldo_pendiente numeric,
  estado_pago text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comercio_id uuid;
  v_compra_id uuid;

  v_numero_pago bigint;
  v_importe numeric(14,2);
  v_estado_pago_registrado text;

  v_total_compra numeric(14,2);

  v_total_pagado_recalculado numeric(14,2);
  v_saldo_pendiente numeric(14,2);
  v_estado_compra_pago text;

  v_motivo text;
begin
  -- ===================================================
  -- AUTENTICACIÓN
  -- ===================================================

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;

  if p_pago_id is null then
    raise exception
      'El pago es obligatorio';
  end if;

  -- Bloqueamos el pago antes de modificarlo.

  select
    pc.comercio_id,
    pc.compra_id,
    pc.numero,
    pc.importe,
    pc.estado
  into
    v_comercio_id,
    v_compra_id,
    v_numero_pago,
    v_importe,
    v_estado_pago_registrado
  from public.pagos_compras as pc
  where pc.id = p_pago_id
  for update;

  if not found then
    raise exception
      'Pago no encontrado';
  end if;

  if not public.pertenece_a_comercio(
    v_comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio del pago';
  end if;

  if v_estado_pago_registrado = 'anulado' then
    raise exception
      'El pago ya se encuentra anulado';
  end if;

  -- ===================================================
  -- MOTIVO
  -- ===================================================

  v_motivo :=
    trim(
      coalesce(
        p_motivo,
        ''
      )
    );

  if char_length(v_motivo) < 3 then
    raise exception
      'El motivo de anulación debe tener al menos 3 caracteres';
  end if;

  if char_length(v_motivo) > 250 then
    raise exception
      'El motivo de anulación no puede superar los 250 caracteres';
  end if;

  -- Bloqueamos también la compra.

  select
    c.total
  into
    v_total_compra
  from public.compras as c
  where c.id = v_compra_id
  for update;

  if not found then
    raise exception
      'La compra asociada al pago no existe';
  end if;

  -- ===================================================
  -- ANULAR PAGO
  -- ===================================================

  update public.pagos_compras as pc
  set
    estado = 'anulado',
    anulado_at = now(),
    anulado_por = auth.uid(),
    motivo_anulacion = v_motivo
  where pc.id = p_pago_id;

  -- ===================================================
  -- RECALCULAR TOTAL PAGADO
  -- ===================================================

  select
    coalesce(
      sum(pc.importe),
      0
    )
  into
    v_total_pagado_recalculado
  from public.pagos_compras as pc
  where pc.compra_id = v_compra_id
    and pc.estado = 'registrado';

  v_total_pagado_recalculado :=
    round(
      v_total_pagado_recalculado,
      2
    );

  v_saldo_pendiente :=
    greatest(
      v_total_compra
      - v_total_pagado_recalculado,
      0
    );

  if v_total_pagado_recalculado <= 0 then
    v_estado_compra_pago :=
      'pendiente';

  elsif v_saldo_pendiente = 0 then
    v_estado_compra_pago :=
      'pagada';

  else
    v_estado_compra_pago :=
      'parcial';
  end if;

  update public.compras as c
  set
    total_pagado =
      v_total_pagado_recalculado,

    estado_pago =
      v_estado_compra_pago
  where c.id = v_compra_id;

  -- ===================================================
  -- RESULTADO
  -- ===================================================

  return query
  select
    p_pago_id,
    v_compra_id,
    v_numero_pago,
    v_importe,
    v_total_pagado_recalculado,
    v_saldo_pendiente,
    v_estado_compra_pago;
end;
$$;

-- =====================================================
-- PERMISOS DE TABLAS
-- =====================================================

revoke all
on public.pago_compra_contadores
from anon;

revoke all
on public.pagos_compras
from anon;

grant select
on public.pago_compra_contadores
to authenticated;

grant select
on public.pagos_compras
to authenticated;

-- =====================================================
-- PERMISOS DE FUNCIONES
-- =====================================================

revoke all
on function public.registrar_pago_compra(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
from public;

grant execute
on function public.registrar_pago_compra(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
to authenticated;

revoke all
on function public.anular_pago_compra(
  uuid,
  text
)
from public;

grant execute
on function public.anular_pago_compra(
  uuid,
  text
)
to authenticated;