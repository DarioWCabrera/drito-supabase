-- =====================================================
-- DRITO - COBROS AGRUPADOS DE CLIENTES
--
-- Un cobro real recibido del cliente genera:
--
--   COB-######  Comprobante principal
--
-- El importe se distribuye internamente:
--
--   PAG-###### -> VTA-######
--   PAG-###### -> VTA-######
--
-- Caja registra solamente el COB principal.
-- =====================================================

-- =====================================================
-- CONTADOR DE COBROS
-- =====================================================

create table if not exists
public.cobro_cliente_contadores (
  comercio_id uuid primary key
    references public.comercios(id)
    on delete cascade,

  ultimo_numero bigint not null
    default 0
    check (ultimo_numero >= 0),

  updated_at timestamptz not null
    default now()
);

-- =====================================================
-- COMPROBANTE PRINCIPAL DE COBRO
-- =====================================================

create table if not exists
public.cobros_clientes (
  id uuid primary key
    default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,

  cliente_id uuid not null
    references public.clientes(id)
    on delete restrict,

  numero bigint not null
    check (numero > 0),

  fecha_cobro date not null
    default current_date,

  importe numeric(14,2) not null
    check (importe > 0),

  medio_pago text not null
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

  -- Referencia externa:
  -- transferencia, cheque, comprobante bancario, etc.

  referencia text,

  observaciones text,

  estado text not null
    default 'registrado'
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

  created_at timestamptz not null
    default now(),

  updated_at timestamptz not null
    default now(),

  unique (
    comercio_id,
    numero
  ),

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
-- APLICACIONES DEL COBRO
--
-- Relaciona el COB principal con cada PAG generado.
-- =====================================================

create table if not exists
public.cobros_clientes_aplicaciones (
  id uuid primary key
    default gen_random_uuid(),

  cobro_cliente_id uuid not null
    references public.cobros_clientes(id)
    on delete restrict,

  venta_id uuid not null
    references public.ventas(id)
    on delete restrict,

  pago_venta_id uuid not null
    references public.pagos_ventas(id)
    on delete restrict,

  importe numeric(14,2) not null
    check (importe > 0),

  created_at timestamptz not null
    default now(),

  unique (
    pago_venta_id
  )
);

-- =====================================================
-- VINCULAR PAGOS DE VENTAS CON EL COBRO PRINCIPAL
-- =====================================================

alter table public.pagos_ventas
add column if not exists
cobro_cliente_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname =
      'pagos_ventas_cobro_cliente_id_fkey'
      and conrelid =
        'public.pagos_ventas'::regclass
  ) then
    alter table public.pagos_ventas
    add constraint
    pagos_ventas_cobro_cliente_id_fkey
    foreign key (
      cobro_cliente_id
    )
    references public.cobros_clientes(id)
    on delete restrict;
  end if;
end;
$$;

-- =====================================================
-- ÍNDICES
-- =====================================================

create index if not exists
cobros_clientes_comercio_fecha_idx
on public.cobros_clientes (
  comercio_id,
  fecha_cobro desc,
  created_at desc
);

create index if not exists
cobros_clientes_cliente_idx
on public.cobros_clientes (
  cliente_id,
  fecha_cobro desc
);

create index if not exists
cobros_clientes_estado_idx
on public.cobros_clientes (
  comercio_id,
  estado
);

create index if not exists
cobros_clientes_aplicaciones_cobro_idx
on public.cobros_clientes_aplicaciones (
  cobro_cliente_id
);

create index if not exists
cobros_clientes_aplicaciones_venta_idx
on public.cobros_clientes_aplicaciones (
  venta_id
);

create index if not exists
pagos_ventas_cobro_cliente_idx
on public.pagos_ventas (
  cobro_cliente_id
)
where cobro_cliente_id is not null;

-- =====================================================
-- UPDATED_AT
-- =====================================================

create or replace function
public.actualizar_cobros_clientes_updated_at()
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
cobros_clientes_updated_at
on public.cobros_clientes;

create trigger
cobros_clientes_updated_at
before update
on public.cobros_clientes
for each row
execute function
public.actualizar_cobros_clientes_updated_at();

-- =====================================================
-- ROW LEVEL SECURITY
-- =====================================================

alter table public.cobro_cliente_contadores
enable row level security;

alter table public.cobros_clientes
enable row level security;

alter table public.cobros_clientes_aplicaciones
enable row level security;

-- =====================================================
-- POLÍTICA DE COBROS
-- =====================================================

drop policy if exists
"Miembros pueden ver cobros de clientes"
on public.cobros_clientes;

create policy
"Miembros pueden ver cobros de clientes"
on public.cobros_clientes
for select
to authenticated
using (
  public.pertenece_a_comercio(
    comercio_id
  )
);

-- =====================================================
-- POLÍTICA DE APLICACIONES
-- =====================================================

drop policy if exists
"Miembros pueden ver aplicaciones de cobros"
on public.cobros_clientes_aplicaciones;

create policy
"Miembros pueden ver aplicaciones de cobros"
on public.cobros_clientes_aplicaciones
for select
to authenticated
using (
  exists (
    select 1
    from public.cobros_clientes as cc
    where cc.id =
      cobro_cliente_id
      and public.pertenece_a_comercio(
        cc.comercio_id
      )
  )
);

-- =====================================================
-- PROTEGER PAGOS AGRUPADOS
--
-- Un PAG vinculado a un COB no puede anularse
-- individualmente desde Ventas.
--
-- Debe anularse el COB completo desde la cuenta
-- corriente del cliente.
-- =====================================================

create or replace function
public.proteger_pago_venta_agrupado()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_contexto_anulacion text;
begin
  if (
    old.cobro_cliente_id is not null
    and old.estado is distinct
      from new.estado
    and new.estado = 'anulado'
  ) then
    v_contexto_anulacion :=
      nullif(
        current_setting(
          'drito.anulando_cobro_cliente_id',
          true
        ),
        ''
      );

    if (
      v_contexto_anulacion is null
      or v_contexto_anulacion <>
        old.cobro_cliente_id::text
    ) then
      raise exception
        'Este pago pertenece a un cobro agrupado. Anulá el comprobante COB completo desde la cuenta corriente del cliente';
    end if;
  end if;

  if (
    old.cobro_cliente_id is not null
    and new.cobro_cliente_id
      is distinct from
      old.cobro_cliente_id
  ) then
    raise exception
      'No se puede modificar la vinculación de un pago agrupado';
  end if;

  return new;
end;
$$;

drop trigger if exists
pagos_ventas_proteger_cobro_agrupado
on public.pagos_ventas;

create trigger
pagos_ventas_proteger_cobro_agrupado
before update
on public.pagos_ventas
for each row
execute function
public.proteger_pago_venta_agrupado();

-- =====================================================
-- ADAPTAR EL TRIGGER DE CAJA
--
-- PAG directo:
--   se registra normalmente en Caja.
--
-- PAG perteneciente a COB:
--   no se registra individualmente.
--
-- El COB principal generará una única entrada.
-- =====================================================

create or replace function
public.sincronizar_pago_con_caja_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cobro_en_proceso text;
begin
  if tg_table_name =
    'pagos_ventas'
  then
    v_cobro_en_proceso :=
      nullif(
        current_setting(
          'drito.cobro_agrupado_id',
          true
        ),
        ''
      );

    -- El pago pertenece a un cobro general.
    -- Caja recibirá únicamente el COB principal.

    if (
      new.cobro_cliente_id
        is not null
      or v_cobro_en_proceso
        is not null
    ) then
      return new;
    end if;

    perform
      public.sincronizar_pago_caja_desde_json(
        'pago_venta',
        to_jsonb(new)
      );

  elsif tg_table_name =
    'pagos_compras'
  then
    perform
      public.sincronizar_pago_caja_desde_json(
        'pago_compra',
        to_jsonb(new)
      );

  else
    raise exception
      'La tabla "%" no está soportada por la integración de Caja',
      tg_table_name;
  end if;

  return new;
end;
$$;

-- Los triggers ya existentes continúan utilizando
-- esta función reemplazada.

-- =====================================================
-- REGISTRAR COBRO AGRUPADO
--
-- Reemplaza la función creada en el archivo 17.
-- Conserva la misma firma para no romper el frontend.
-- =====================================================

create or replace function
public.registrar_cobro_cuenta_cliente(
  p_cliente_id uuid,
  p_importe numeric,
  p_fecha_pago date,
  p_medio_pago text,
  p_referencia text default null,
  p_observaciones text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comercio_id uuid;
  v_nombre_cliente text;

  v_numero_cobro bigint;
  v_cobro_id uuid;

  v_comprobante_cobro text;

  v_importe numeric(14,2);
  v_saldo_total numeric(14,2);
  v_saldo_final numeric(14,2);

  v_restante numeric(14,2);
  v_importe_aplicado numeric(14,2);

  v_medio_pago text;
  v_referencia text;
  v_observaciones text;

  v_categoria_caja_id uuid;

  v_ventas_afectadas integer :=
    0;

  v_asignaciones jsonb :=
    '[]'::jsonb;

  v_venta record;
  v_pago record;
begin
  -- ===================================================
  -- AUTENTICACIÓN
  -- ===================================================

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;

  if p_cliente_id is null then
    raise exception
      'El cliente es obligatorio';
  end if;

  -- ===================================================
  -- CLIENTE
  -- ===================================================

  select
    cl.comercio_id,

    coalesce(
      nullif(
        trim(cl.razon_social),
        ''
      ),

      nullif(
        trim(cl.nombre),
        ''
      ),

      'Cliente sin nombre'
    )

  into
    v_comercio_id,
    v_nombre_cliente

  from public.clientes as cl

  where cl.id =
    p_cliente_id

  for update;

  if not found then
    raise exception
      'Cliente no encontrado';
  end if;

  if not public.pertenece_a_comercio(
    v_comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio del cliente';
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
  -- FECHA
  -- ===================================================

  if p_fecha_pago is null then
    raise exception
      'La fecha del cobro es obligatoria';
  end if;

  if p_fecha_pago >
    current_date
  then
    raise exception
      'La fecha del cobro no puede ser futura';
  end if;

  -- ===================================================
  -- MEDIO DE PAGO
  -- ===================================================

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
      'El medio de pago es inválido';
  end if;

  v_referencia :=
    nullif(
      trim(
        coalesce(
          p_referencia,
          ''
        )
      ),
      ''
    );

  v_observaciones :=
    nullif(
      trim(
        coalesce(
          p_observaciones,
          ''
        )
      ),
      ''
    );

  -- ===================================================
  -- BLOQUEAR VENTAS DEL CLIENTE
  --
  -- Evita que otro pago modifique los saldos mientras
  -- se distribuye este cobro.
  -- ===================================================

  perform
    1

  from public.ventas as v

  where v.comercio_id =
    v_comercio_id

    and v.cliente_id =
      p_cliente_id

    and v.estado =
      'confirmada'

  order by
    v.fecha_venta asc,
    v.numero asc

  for update;

  -- ===================================================
  -- SALDO TOTAL
  -- ===================================================

  select
    coalesce(
      sum(
        greatest(
          v.total
          -
          coalesce(
            v.total_pagado,
            0
          ),
          0
        )
      ),
      0
    )::numeric(14,2)

  into
    v_saldo_total

  from public.ventas as v

  where v.comercio_id =
    v_comercio_id

    and v.cliente_id =
      p_cliente_id

    and v.estado =
      'confirmada';

  if v_saldo_total <= 0 then
    raise exception
      'El cliente no tiene saldo pendiente';
  end if;

  if v_importe >
    v_saldo_total
  then
    raise exception
      'El importe supera el saldo pendiente del cliente. Saldo actual: %',
      v_saldo_total;
  end if;

  -- ===================================================
  -- GENERAR NÚMERO COB
  -- ===================================================

  insert into
  public.cobro_cliente_contadores (
    comercio_id,
    ultimo_numero,
    updated_at
  )
  values (
    v_comercio_id,
    1,
    now()
  )

  on conflict (
    comercio_id
  )
  do update set
    ultimo_numero =
      public.cobro_cliente_contadores
        .ultimo_numero + 1,

    updated_at = now()

  returning ultimo_numero
  into v_numero_cobro;

  v_comprobante_cobro :=
    format(
      'COB-%s',
      lpad(
        v_numero_cobro::text,
        6,
        '0'
      )
    );

  -- ===================================================
  -- CREAR COMPROBANTE PRINCIPAL
  -- ===================================================

  insert into public.cobros_clientes (
    comercio_id,
    cliente_id,
    numero,
    fecha_cobro,
    importe,
    medio_pago,
    referencia,
    observaciones,
    estado,
    creado_por
  )
  values (
    v_comercio_id,
    p_cliente_id,
    v_numero_cobro,
    p_fecha_pago,
    v_importe,
    v_medio_pago,
    v_referencia,
    v_observaciones,
    'registrado',
    auth.uid()
  )

  returning id
  into v_cobro_id;

  -- ===================================================
  -- AVISAR AL TRIGGER DE CAJA
  --
  -- Mientras dure esta transacción, los PAG internos
  -- no deben generar movimientos individuales.
  -- ===================================================

  perform
    set_config(
      'drito.cobro_agrupado_id',
      v_cobro_id::text,
      true
    );

  -- ===================================================
  -- DISTRIBUIR COBRO
  -- ===================================================

  v_restante :=
    v_importe;

  for v_venta in
    select
      v.id,
      v.numero,
      v.fecha_venta,

      greatest(
        v.total
        -
        coalesce(
          v.total_pagado,
          0
        ),
        0
      )::numeric(14,2)
        as saldo_pendiente

    from public.ventas as v

    where v.comercio_id =
      v_comercio_id

      and v.cliente_id =
        p_cliente_id

      and v.estado =
        'confirmada'

      and greatest(
        v.total
        -
        coalesce(
          v.total_pagado,
          0
        ),
        0
      ) > 0

    order by
      v.fecha_venta asc,
      v.numero asc

    for update
  loop
    exit when v_restante <= 0;

    v_importe_aplicado :=
      least(
        v_restante,
        v_venta.saldo_pendiente
      );

    -- ===============================================
    -- CREAR PAG INTERNO
    -- ===============================================

    select
      *

    into
      v_pago

    from public.registrar_pago_venta(
      v_venta.id,
      v_importe_aplicado,
      p_fecha_pago,
      v_medio_pago,

      -- El PAG queda vinculado al COB.

      v_comprobante_cobro,

      coalesce(
        v_observaciones,
        format(
          'Aplicación del cobro agrupado %s',
          v_comprobante_cobro
        )
      )
    );

    -- ===============================================
    -- VINCULAR EL PAG AL COB
    --
    -- Esta actualización también dispara el trigger,
    -- pero ya será ignorada porque cobro_cliente_id
    -- tendrá un valor.
    -- ===============================================

    update public.pagos_ventas
    set
      cobro_cliente_id =
        v_cobro_id
    where id =
      v_pago.pago_id;

    -- ===============================================
    -- GUARDAR APLICACIÓN
    -- ===============================================

    insert into
    public.cobros_clientes_aplicaciones (
      cobro_cliente_id,
      venta_id,
      pago_venta_id,
      importe
    )
    values (
      v_cobro_id,
      v_venta.id,
      v_pago.pago_id,
      v_importe_aplicado
    );

    v_ventas_afectadas :=
      v_ventas_afectadas + 1;

    v_asignaciones :=
      v_asignaciones
      ||
      jsonb_build_array(
        jsonb_build_object(
          'venta_id',
            v_venta.id,

          'numero_venta',
            v_venta.numero,

          'fecha_venta',
            v_venta.fecha_venta,

          'importe_aplicado',
            v_importe_aplicado,

          'pago_id',
            v_pago.pago_id,

          'numero_pago',
            v_pago.numero_pago,

          'saldo_venta',
            v_pago.saldo_pendiente,

          'estado_pago',
            v_pago.estado_pago
        )
      );

    v_restante :=
      round(
        v_restante
        -
        v_importe_aplicado,
        2
      );
  end loop;

  if v_restante > 0 then
    raise exception
      'No fue posible aplicar la totalidad del cobro';
  end if;

  -- ===================================================
  -- REGISTRAR UN ÚNICO MOVIMIENTO EN CAJA
  -- ===================================================

  v_categoria_caja_id :=
    public.obtener_o_crear_categoria_caja_sistema(
      v_comercio_id,
      'Cobro de venta',
      'ingreso'
    );

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
    referencia_tipo,
    referencia_id,
    estado,
    creado_por
  )
  values (
    v_comercio_id,
    v_categoria_caja_id,
    'ingreso',

    -- Se mantiene "venta" para respetar los valores
    -- admitidos actualmente por movimientos_caja.

    'venta',

    p_fecha_pago,
    v_importe,
    v_medio_pago,

    format(
      'Cobro cuenta corriente - %s',
      v_nombre_cliente
    ),

    v_comprobante_cobro,

    nullif(
      concat_ws(
        ' · ',
        v_referencia,
        v_observaciones
      ),
      ''
    ),

    'cobro_cliente',
    v_cobro_id,
    'registrado',
    auth.uid()
  );

  -- ===================================================
  -- SALDO FINAL
  -- ===================================================

  select
    coalesce(
      sum(
        greatest(
          v.total
          -
          coalesce(
            v.total_pagado,
            0
          ),
          0
        )
      ),
      0
    )::numeric(14,2)

  into
    v_saldo_final

  from public.ventas as v

  where v.comercio_id =
    v_comercio_id

    and v.cliente_id =
      p_cliente_id

    and v.estado =
      'confirmada';

  -- ===================================================
  -- RESPUESTA
  -- ===================================================

  return jsonb_build_object(
    'cobro_id',
      v_cobro_id,

    'numero_cobro',
      v_numero_cobro,

    'comprobante',
      v_comprobante_cobro,

    'cliente_id',
      p_cliente_id,

    'nombre_cliente',
      v_nombre_cliente,

    'importe_recibido',
      v_importe,

    'saldo_anterior',
      v_saldo_total,

    'saldo_final',
      v_saldo_final,

    'ventas_afectadas',
      v_ventas_afectadas,

    'asignaciones',
      v_asignaciones
  );
end;
$$;

-- =====================================================
-- ANULAR COBRO AGRUPADO
--
-- Anula:
--   - todos los PAG internos
--   - el movimiento único de Caja
--   - el comprobante COB
--
-- Las ventas recuperan sus saldos pendientes.
-- =====================================================

create or replace function
public.anular_cobro_cuenta_cliente(
  p_cobro_id uuid,
  p_motivo text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comercio_id uuid;
  v_cliente_id uuid;

  v_numero bigint;
  v_importe numeric(14,2);
  v_estado text;

  v_motivo text;

  v_pagos_anulados integer :=
    0;

  v_movimientos_caja integer :=
    0;

  v_aplicacion record;
begin
  -- ===================================================
  -- AUTENTICACIÓN
  -- ===================================================

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;

  if p_cobro_id is null then
    raise exception
      'El cobro es obligatorio';
  end if;

  -- ===================================================
  -- COBRO
  -- ===================================================

  select
    cc.comercio_id,
    cc.cliente_id,
    cc.numero,
    cc.importe,
    cc.estado

  into
    v_comercio_id,
    v_cliente_id,
    v_numero,
    v_importe,
    v_estado

  from public.cobros_clientes as cc

  where cc.id =
    p_cobro_id

  for update;

  if not found then
    raise exception
      'Cobro no encontrado';
  end if;

  if not public.pertenece_a_comercio(
    v_comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio del cobro';
  end if;

  if v_estado =
    'anulado'
  then
    raise exception
      'El cobro ya se encuentra anulado';
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
      'El motivo debe tener al menos 3 caracteres';
  end if;

  if char_length(v_motivo) > 250 then
    raise exception
      'El motivo no puede superar los 250 caracteres';
  end if;

  -- ===================================================
  -- CONTEXTO DE ANULACIÓN
  --
  -- Autoriza al trigger protector a anular los PAG.
  -- ===================================================

  perform
    set_config(
      'drito.anulando_cobro_cliente_id',
      p_cobro_id::text,
      true
    );

  -- ===================================================
  -- ANULAR PAGOS INTERNOS
  -- ===================================================

  for v_aplicacion in
    select
      cca.pago_venta_id,
      pv.estado

    from
    public.cobros_clientes_aplicaciones
      as cca

    inner join public.pagos_ventas
      as pv
      on pv.id =
        cca.pago_venta_id

    where cca.cobro_cliente_id =
      p_cobro_id

    order by
      cca.created_at desc

    for update of pv
  loop
    if v_aplicacion.estado <>
      'registrado'
    then
      raise exception
        'El cobro agrupado contiene un pago interno que ya fue anulado';
    end if;

    perform
      public.anular_pago_venta(
        v_aplicacion.pago_venta_id,
        format(
          'Anulación de COB-%s: %s',
          lpad(
            v_numero::text,
            6,
            '0'
          ),
          v_motivo
        )
      );

    v_pagos_anulados :=
      v_pagos_anulados + 1;
  end loop;

  if v_pagos_anulados = 0 then
    raise exception
      'El cobro no contiene pagos asociados';
  end if;

  -- ===================================================
  -- ANULAR MOVIMIENTO DE CAJA
  -- ===================================================

  update public.movimientos_caja
  set
    estado = 'anulado',
    anulado_at = now(),
    anulado_por = auth.uid(),

    motivo_anulacion =
      format(
        'Anulación de COB-%s: %s',
        lpad(
          v_numero::text,
          6,
          '0'
        ),
        v_motivo
      )

  where comercio_id =
    v_comercio_id

    and referencia_tipo =
      'cobro_cliente'

    and referencia_id =
      p_cobro_id

    and estado =
      'registrado';

  get diagnostics
    v_movimientos_caja =
      row_count;

  if v_movimientos_caja <> 1 then
    raise exception
      'No se encontró el movimiento único de Caja correspondiente al cobro';
  end if;

  -- ===================================================
  -- ANULAR COB
  -- ===================================================

  update public.cobros_clientes
  set
    estado = 'anulado',
    anulado_at = now(),
    anulado_por = auth.uid(),
    motivo_anulacion = v_motivo

  where id =
    p_cobro_id;

  -- ===================================================
  -- RESPUESTA
  -- ===================================================

  return jsonb_build_object(
    'cobro_id',
      p_cobro_id,

    'numero_cobro',
      v_numero,

    'comprobante',
      format(
        'COB-%s',
        lpad(
          v_numero::text,
          6,
          '0'
        )
      ),

    'cliente_id',
      v_cliente_id,

    'importe_anulado',
      v_importe,

    'pagos_anulados',
      v_pagos_anulados,

    'estado',
      'anulado'
  );
end;
$$;

-- =====================================================
-- PERMISOS DE TABLAS
-- =====================================================

revoke all
on public.cobro_cliente_contadores
from anon;

revoke all
on public.cobro_cliente_contadores
from authenticated;

revoke all
on public.cobros_clientes
from anon;

revoke all
on public.cobros_clientes_aplicaciones
from anon;

grant select
on public.cobros_clientes
to authenticated;

grant select
on public.cobros_clientes_aplicaciones
to authenticated;

-- =====================================================
-- PERMISOS DE FUNCIONES
-- =====================================================

revoke all
on function
public.registrar_cobro_cuenta_cliente(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
from public;

grant execute
on function
public.registrar_cobro_cuenta_cliente(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
to authenticated;

revoke all
on function
public.anular_cobro_cuenta_cliente(
  uuid,
  text
)
from public;

grant execute
on function
public.anular_cobro_cuenta_cliente(
  uuid,
  text
)
to authenticated;

revoke all
on function
public.proteger_pago_venta_agrupado()
from public;

-- =====================================================
-- ACTUALIZAR CACHÉ DE SUPABASE
-- =====================================================

notify pgrst, 'reload schema';