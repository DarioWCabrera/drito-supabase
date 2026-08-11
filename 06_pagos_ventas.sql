-- =====================================================
-- DRITO - PAGOS DE VENTAS
-- =====================================================

-- =====================================================
-- CONTADOR DE PAGOS POR COMERCIO
-- =====================================================

create table if not exists public.pago_contadores (
  comercio_id uuid primary key
    references public.comercios(id) on delete cascade,

  ultimo_numero bigint not null default 0
    check (ultimo_numero >= 0),

  updated_at timestamptz not null default now()
);

-- =====================================================
-- PAGOS
-- =====================================================

create table if not exists public.pagos_ventas (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  venta_id uuid not null
    references public.ventas(id) on delete restrict,

  numero bigint not null
    check (numero > 0),

  fecha_pago date not null default current_date,

  importe numeric(14,2) not null
    check (importe > 0),

  moneda text not null default 'ARS',

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
    references auth.users(id) on delete set null,

  anulado_por uuid
    references auth.users(id) on delete set null,

  anulado_at timestamptz,
  motivo_anulacion text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (comercio_id, numero),

  check (
    (
      estado = 'registrado'
      and anulado_at is null
      and anulado_por is null
    )
    or
    (
      estado = 'anulado'
      and anulado_at is not null
      and anulado_por is not null
      and motivo_anulacion is not null
      and char_length(trim(motivo_anulacion)) >= 3
    )
  )
);

-- =====================================================
-- ÍNDICES
-- =====================================================

create index if not exists pagos_ventas_comercio_fecha_idx
on public.pagos_ventas (
  comercio_id,
  fecha_pago desc,
  created_at desc
);

create index if not exists pagos_ventas_venta_fecha_idx
on public.pagos_ventas (
  venta_id,
  fecha_pago desc,
  created_at desc
);

create index if not exists pagos_ventas_estado_idx
on public.pagos_ventas (
  comercio_id,
  estado
);

create index if not exists pagos_ventas_medio_pago_idx
on public.pagos_ventas (
  comercio_id,
  medio_pago
);

-- =====================================================
-- UPDATED_AT
-- =====================================================

drop trigger if exists pagos_ventas_updated_at
on public.pagos_ventas;

create trigger pagos_ventas_updated_at
before update on public.pagos_ventas
for each row
execute function public.actualizar_updated_at();

-- =====================================================
-- REGISTRAR PAGO
-- =====================================================

create or replace function public.registrar_pago_venta(
  p_venta_id uuid,
  p_importe numeric,
  p_fecha_pago date default current_date,
  p_medio_pago text default 'efectivo',
  p_referencia text default null,
  p_observaciones text default null
)
returns table (
  pago_id uuid,
  numero_pago bigint,
  venta_id uuid,
  total_pagado numeric,
  saldo_pendiente numeric,
  estado_pago text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venta public.ventas%rowtype;

  v_pago_id uuid;
  v_numero_pago bigint;

  v_importe numeric(14,2);
  v_saldo_anterior numeric(14,2);
  v_total_pagado numeric(14,2);
  v_saldo_pendiente numeric(14,2);

  v_estado_pago text;
  v_medio_pago text;
begin
  -- ===================================================
  -- VALIDACIONES GENERALES
  -- ===================================================

  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if p_venta_id is null then
    raise exception 'La venta es obligatoria';
  end if;

  if p_importe is null then
    raise exception 'El importe es obligatorio';
  end if;

  v_importe := round(p_importe, 2);

  if v_importe <= 0 then
    raise exception
      'El importe del pago debe ser mayor que cero';
  end if;

  if p_fecha_pago is null then
    raise exception
      'La fecha del pago es obligatoria';
  end if;

  if p_fecha_pago > current_date then
    raise exception
      'La fecha del pago no puede ser futura';
  end if;

  v_medio_pago :=
    lower(
      trim(
        coalesce(
          p_medio_pago,
          ''
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
      'El medio de pago indicado no es válido';
  end if;

  -- Bloquear la venta durante toda la operación.
  -- Esto evita registrar dos pagos simultáneos que
  -- superen el total de la venta.

  select v.*
  into v_venta
  from public.ventas as v
  where v.id = p_venta_id
  for update;

  if not found then
    raise exception 'Venta no encontrada';
  end if;

  if not public.pertenece_a_comercio(
    v_venta.comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio';
  end if;

  if v_venta.estado <> 'confirmada' then
    raise exception
      'No se pueden registrar pagos en una venta anulada';
  end if;

  if p_fecha_pago < v_venta.fecha_venta then
    raise exception
      'La fecha del pago no puede ser anterior a la venta';
  end if;

  v_saldo_anterior :=
    round(
      v_venta.total - v_venta.total_pagado,
      2
    );

  if v_saldo_anterior <= 0 then
    raise exception
      'La venta ya se encuentra pagada';
  end if;

  if v_importe > v_saldo_anterior then
    raise exception
      'El pago supera el saldo pendiente. Saldo disponible: %',
      v_saldo_anterior;
  end if;

  -- ===================================================
  -- GENERAR NÚMERO DE PAGO
  -- ===================================================

  insert into public.pago_contadores (
    comercio_id,
    ultimo_numero,
    updated_at
  )
  values (
    v_venta.comercio_id,
    1,
    now()
  )
  on conflict (comercio_id)
  do update set
    ultimo_numero =
      public.pago_contadores.ultimo_numero + 1,

    updated_at = now()

  returning ultimo_numero
  into v_numero_pago;

  -- ===================================================
  -- REGISTRAR PAGO
  -- ===================================================

  insert into public.pagos_ventas (
    comercio_id,
    venta_id,
    numero,
    fecha_pago,
    importe,
    moneda,
    medio_pago,
    referencia,
    observaciones,
    estado,
    creado_por
  )
  values (
    v_venta.comercio_id,
    v_venta.id,
    v_numero_pago,
    p_fecha_pago,
    v_importe,
    v_venta.moneda,
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

  -- Se calcula desde el historial real de pagos para
  -- evitar diferencias con ventas.total_pagado.

  select
    coalesce(
      sum(p.importe),
      0
    )::numeric(14,2)
  into v_total_pagado
  from public.pagos_ventas as p
  where p.venta_id = v_venta.id
    and p.estado = 'registrado';

  v_saldo_pendiente :=
    greatest(
      round(
        v_venta.total - v_total_pagado,
        2
      ),
      0
    );

  if v_saldo_pendiente = 0 then
    v_estado_pago := 'pagada';

  elsif v_total_pagado > 0 then
    v_estado_pago := 'parcial';

  else
    v_estado_pago := 'pendiente';
  end if;

  -- ===================================================
  -- ACTUALIZAR VENTA
  -- ===================================================

  update public.ventas as v
  set
    total_pagado = v_total_pagado,
    estado_pago = v_estado_pago
  where v.id = v_venta.id;

  -- ===================================================
  -- DEVOLVER RESULTADO
  -- ===================================================

  return query
  select
    v_pago_id,
    v_numero_pago,
    v_venta.id,
    v_total_pagado,
    v_saldo_pendiente,
    v_estado_pago;
end;
$$;

-- =====================================================
-- ANULAR PAGO
-- =====================================================

create or replace function public.anular_pago_venta(
  p_pago_id uuid,
  p_motivo text
)
returns table (
  pago_id uuid,
  venta_id uuid,
  total_pagado numeric,
  saldo_pendiente numeric,
  estado_pago text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pago public.pagos_ventas%rowtype;
  v_venta public.ventas%rowtype;

  v_motivo text;

  v_total_pagado numeric(14,2);
  v_saldo_pendiente numeric(14,2);
  v_estado_pago text;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if p_pago_id is null then
    raise exception 'El pago es obligatorio';
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
      'Ingresá un motivo de anulación válido';
  end if;

  -- Bloquear el pago.

  select p.*
  into v_pago
  from public.pagos_ventas as p
  where p.id = p_pago_id
  for update;

  if not found then
    raise exception 'Pago no encontrado';
  end if;

  if not public.pertenece_a_comercio(
    v_pago.comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio';
  end if;

  if v_pago.estado = 'anulado' then
    raise exception
      'El pago ya se encuentra anulado';
  end if;

  -- Bloquear la venta correspondiente.

  select v.*
  into v_venta
  from public.ventas as v
  where v.id = v_pago.venta_id
  for update;

  if not found then
    raise exception
      'La venta asociada al pago no existe';
  end if;

  if v_venta.estado <> 'confirmada' then
    raise exception
      'No se puede anular un pago de una venta anulada';
  end if;

  -- ===================================================
  -- ANULAR SIN ELIMINAR EL REGISTRO
  -- ===================================================

  update public.pagos_ventas as p
  set
    estado = 'anulado',
    anulado_por = auth.uid(),
    anulado_at = now(),
    motivo_anulacion = v_motivo
  where p.id = v_pago.id;

  -- Recalcular el total desde todos los pagos vigentes.

  select
    coalesce(
      sum(p.importe),
      0
    )::numeric(14,2)
  into v_total_pagado
  from public.pagos_ventas as p
  where p.venta_id = v_venta.id
    and p.estado = 'registrado';

  v_saldo_pendiente :=
    greatest(
      round(
        v_venta.total - v_total_pagado,
        2
      ),
      0
    );

  if v_saldo_pendiente = 0 then
    v_estado_pago := 'pagada';

  elsif v_total_pagado > 0 then
    v_estado_pago := 'parcial';

  else
    v_estado_pago := 'pendiente';
  end if;

  update public.ventas as v
  set
    total_pagado = v_total_pagado,
    estado_pago = v_estado_pago
  where v.id = v_venta.id;

  return query
  select
    v_pago.id,
    v_venta.id,
    v_total_pagado,
    v_saldo_pendiente,
    v_estado_pago;
end;
$$;

-- =====================================================
-- ROW LEVEL SECURITY
-- =====================================================

alter table public.pagos_ventas
enable row level security;

alter table public.pago_contadores
enable row level security;

drop policy if exists pagos_ventas_select_miembro
on public.pagos_ventas;

create policy pagos_ventas_select_miembro
on public.pagos_ventas
for select
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
);

-- Los contadores no tienen políticas de lectura.
-- Solo son utilizados por las funciones seguras.

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on public.pagos_ventas
from anon, authenticated;

revoke all
on public.pago_contadores
from anon, authenticated;

grant select
on public.pagos_ventas
to authenticated;

revoke all
on function public.registrar_pago_venta(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
from public;

grant execute
on function public.registrar_pago_venta(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
to authenticated;

revoke all
on function public.anular_pago_venta(
  uuid,
  text
)
from public;

grant execute
on function public.anular_pago_venta(
  uuid,
  text
)
to authenticated;