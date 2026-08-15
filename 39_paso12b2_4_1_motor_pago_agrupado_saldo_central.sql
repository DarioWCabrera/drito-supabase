-- =============================================================
-- DRITO - PASO 12B.2.4.1
-- PAGO AGRUPADO DE PROVEEDOR SOBRE SALDO CENTRAL
-- =============================================================
--
-- Objetivo:
--
-- corregir el motor histórico registrar_pago_cuenta_proveedor()
-- para que el saldo del proveedor y la asignación FIFO utilicen
-- el motor central de cancelación:
--
--   dinero + retenciones practicadas = deuda cancelada
--
-- Caja continúa representando solamente dinero real.
--
-- Este paso NO crea todavía retenciones agrupadas.
-- Prepara correctamente el circuito existente para 12B.2.4.2.
-- =============================================================

begin;


-- =============================================================
-- 0. PRECONDICIONES
-- =============================================================

do $$
begin

  if to_regprocedure(
    'public.__drito_calcular_cancelacion_compra(uuid)'
  ) is null then
    raise exception
      'Falta __drito_calcular_cancelacion_compra(uuid)';
  end if;


  if to_regprocedure(
    'public.__drito_original_registrar_pago_cuenta_proveedor_08bf6aac1e(uuid,date,numeric,text,text,text)'
  ) is null then
    raise exception
      'No se encontró el motor interno histórico de pago agrupado';
  end if;


  if to_regprocedure(
    'public.crear_pago_compra_interno_proveedor(uuid,uuid,bigint,date,numeric,text,text,text,uuid)'
  ) is null then
    raise exception
      'Falta crear_pago_compra_interno_proveedor';
  end if;


  if to_regprocedure(
    'public.registrar_caja_pago_proveedor(uuid,uuid,date,numeric,text,text,text,text,bigint)'
  ) is null then
    raise exception
      'Falta registrar_caja_pago_proveedor';
  end if;

end;
$$;


-- =============================================================
-- 1. REEMPLAZAR MOTOR INTERNO DEL PAGO AGRUPADO
-- =============================================================
--
-- Se conserva:
--
--   - nombre
--   - firma
--   - retorno
--   - wrapper público
--   - comprobante PPR
--   - PAG internos
--   - un único movimiento de Caja
--
-- Cambio:
--
-- saldo proveedor y saldo de cada compra salen del motor
-- central de cancelación, no de SUM(pagos_compras.importe).
-- =============================================================

create or replace function
public.__drito_original_registrar_pago_cuenta_proveedor_08bf6aac1e(

  p_proveedor_id uuid,

  p_fecha_pago date,

  p_importe numeric,

  p_medio_pago text,

  p_referencia text default null,

  p_observaciones text default null

)
returns table (

  pago_proveedor_id uuid,

  numero_pago_proveedor bigint,

  comprobante text,

  nombre_proveedor text,

  importe_pagado numeric,

  compras_afectadas integer,

  pagos_generados integer,

  saldo_anterior numeric,

  saldo_final numeric,

  movimiento_caja_id uuid

)
language plpgsql
security definer
set search_path = public
as $$
declare

  v_comercio_id uuid;

  v_nombre_proveedor text;

  v_numero_ppr bigint;

  v_pago_proveedor_id uuid;

  v_movimiento_caja_id uuid;

  v_saldo_anterior numeric(14,2) := 0;

  v_saldo_final numeric(14,2) := 0;

  v_restante numeric(14,2);

  v_aplicado numeric(14,2);

  -- Se conserva por compatibilidad con la firma histórica
  -- de crear_pago_compra_interno_proveedor().
  -- Desde el paso 38 el helper genera internamente
  -- la numeración PAG centralizada.
  v_numero_pago_compat bigint := 0;

  v_pago_compra_id uuid;

  v_compras_afectadas integer := 0;

  v_pagos_generados integer := 0;

  v_compra record;

begin

  -- ===========================================================
  -- AUTENTICACIÓN
  -- ===========================================================

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;


  -- ===========================================================
  -- VALIDACIONES BÁSICAS
  -- ===========================================================

  if p_proveedor_id is null then
    raise exception
      'El proveedor es obligatorio';
  end if;


  if p_fecha_pago is null then
    raise exception
      'La fecha del pago es obligatoria';
  end if;


  if p_fecha_pago > current_date then
    raise exception
      'La fecha del pago no puede ser futura';
  end if;


  if p_importe is null
    or round(p_importe, 2) <= 0 then

    raise exception
      'El importe debe ser mayor a cero';

  end if;


  if nullif(
    trim(
      coalesce(
        p_medio_pago,
        ''
      )
    ),
    ''
  ) is null then

    raise exception
      'El medio de pago es obligatorio';

  end if;


  -- ===========================================================
  -- PROVEEDOR
  -- ===========================================================

  select

    pr.comercio_id,

    coalesce(

      nullif(
        trim(
          to_jsonb(pr) ->> 'razon_social'
        ),
        ''
      ),

      nullif(
        trim(
          to_jsonb(pr) ->> 'nombre'
        ),
        ''
      ),

      nullif(
        trim(
          to_jsonb(pr) ->> 'nombre_fantasia'
        ),
        ''
      ),

      'Proveedor sin nombre'

    )

  into

    v_comercio_id,

    v_nombre_proveedor

  from public.proveedores pr

  where pr.id =
    p_proveedor_id;


  if not found then
    raise exception
      'Proveedor no encontrado';
  end if;


  if not public.pertenece_a_comercio(
    v_comercio_id
  ) then

    raise exception
      'El usuario no pertenece al comercio del proveedor';

  end if;


  -- ===========================================================
  -- SERIALIZACIÓN DE LA CUENTA DEL PROVEEDOR
  -- ===========================================================

  perform pg_advisory_xact_lock(

    hashtextextended(

      v_comercio_id::text
      || ':'
      || p_proveedor_id::text,

      0

    )

  );


  -- Mantiene compatibilidad con la serialización PAG.
  -- El generador definitivo está centralizado desde el paso 38.

  perform pg_advisory_xact_lock(

    hashtextextended(

      v_comercio_id::text
      || ':pagos_compras',

      0

    )

  );


  -- ===========================================================
  -- SALDO TOTAL DEL PROVEEDOR
  --
  -- FUENTE DE VERDAD:
  -- __drito_calcular_cancelacion_compra()
  -- ===========================================================

  select

    coalesce(
      sum(r.saldo_pendiente),
      0
    )::numeric(14,2)

  into v_saldo_anterior

  from public.compras c

  cross join lateral

    public.__drito_calcular_cancelacion_compra(
      c.id
    ) r

  where c.comercio_id =
    v_comercio_id

    and c.proveedor_id =
      p_proveedor_id

    and c.estado =
      'confirmada';


  if v_saldo_anterior <= 0 then
    raise exception
      'El proveedor no posee saldo pendiente';
  end if;


  if round(
    p_importe,
    2
  ) > v_saldo_anterior then

    raise exception
      'El importe supera el saldo pendiente del proveedor. Saldo disponible: %',
      v_saldo_anterior;

  end if;


  -- ===========================================================
  -- GENERAR NÚMERO PPR
  -- ===========================================================

  insert into public.pago_proveedor_contadores (

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
      public.pago_proveedor_contadores.ultimo_numero
      + 1,

    updated_at =
      now()

  returning ultimo_numero

  into v_numero_ppr;


  -- ===========================================================
  -- CREAR PPR
  --
  -- importe = dinero real que sale.
  -- ===========================================================

  insert into public.pagos_proveedores (

    comercio_id,

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

    p_proveedor_id,

    v_numero_ppr,

    p_fecha_pago,

    round(
      p_importe,
      2
    ),

    trim(
      p_medio_pago
    ),

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

  into v_pago_proveedor_id;


  -- ===========================================================
  -- DINERO A DISTRIBUIR
  -- ===========================================================

  v_restante :=
    round(
      p_importe,
      2
    );


  -- ===========================================================
  -- FIFO SOBRE SALDO CENTRAL
  --
  -- Si una compra ya fue parcialmente cancelada mediante
  -- retenciones, ese importe ya NO vuelve a formar parte
  -- del saldo disponible para el dinero.
  -- ===========================================================

  for v_compra in

    select

      c.id,

      c.numero,

      c.fecha_compra,

      c.created_at,

      r.saldo_pendiente::numeric(14,2)
        as saldo_pendiente

    from public.compras c

    cross join lateral

      public.__drito_calcular_cancelacion_compra(
        c.id
      ) r

    where c.comercio_id =
      v_comercio_id

      and c.proveedor_id =
        p_proveedor_id

      and c.estado =
        'confirmada'

      and r.saldo_pendiente > 0

    order by

      c.fecha_compra asc,

      c.numero asc,

      c.created_at asc,

      c.id asc

    for update of c

  loop

    exit when v_restante <= 0;


    v_aplicado :=

      least(

        v_restante,

        v_compra.saldo_pendiente

      );


    -- El parámetro numérico se conserva únicamente
    -- por compatibilidad de firma.
    -- El helper del paso 38 obtiene el PAG real
    -- mediante el generador único.

    v_pago_compra_id :=

      public.crear_pago_compra_interno_proveedor(

        v_comercio_id,

        v_compra.id,

        v_numero_pago_compat,

        p_fecha_pago,

        v_aplicado,

        trim(
          p_medio_pago
        ),

        coalesce(

          nullif(
            trim(
              coalesce(
                p_referencia,
                ''
              )
            ),
            ''
          ),

          format(
            'PPR-%s',
            lpad(
              v_numero_ppr::text,
              6,
              '0'
            )
          )

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

        v_pago_proveedor_id

      );


    -- =========================================================
    -- APLICACIÓN HISTÓRICA DEL DINERO PPR
    -- =========================================================

    insert into public.pagos_proveedores_aplicaciones (

      pago_proveedor_id,

      compra_id,

      pago_compra_id,

      importe_aplicado

    )
    values (

      v_pago_proveedor_id,

      v_compra.id,

      v_pago_compra_id,

      v_aplicado

    );


    -- =========================================================
    -- SINCRONIZAR RESUMEN DE LA COMPRA
    --
    -- Desde 12B.2.2 este helper usa el motor central.
    -- =========================================================

    perform public.actualizar_resumen_pago_compra(
      v_compra.id
    );


    v_restante :=

      round(

        v_restante
        - v_aplicado,

        2

      );


    v_compras_afectadas :=
      v_compras_afectadas + 1;


    v_pagos_generados :=
      v_pagos_generados + 1;

  end loop;


  -- ===========================================================
  -- CONTROL DE INTEGRIDAD
  -- ===========================================================

  if v_restante > 0 then
    raise exception
      'No se pudo aplicar completamente el pago';
  end if;


  -- ===========================================================
  -- SALDO FINAL
  -- ===========================================================

  v_saldo_final :=

    greatest(

      round(

        v_saldo_anterior
        - p_importe,

        2

      ),

      0

    );


  -- ===========================================================
  -- CAJA
  --
  -- UN solo egreso por el PPR.
  -- El PAG interno no mueve Caja.
  -- ===========================================================

  v_movimiento_caja_id :=

    public.registrar_caja_pago_proveedor(

      v_pago_proveedor_id,

      v_comercio_id,

      p_fecha_pago,

      round(
        p_importe,
        2
      ),

      trim(
        p_medio_pago
      ),

      p_referencia,

      p_observaciones,

      v_nombre_proveedor,

      v_numero_ppr

    );


  -- ===========================================================
  -- RESULTADO
  -- ===========================================================

  return query

  select

    v_pago_proveedor_id,

    v_numero_ppr,

    format(

      'PPR-%s',

      lpad(
        v_numero_ppr::text,
        6,
        '0'
      )

    ),

    v_nombre_proveedor,

    round(
      p_importe,
      2
    ),

    v_compras_afectadas,

    v_pagos_generados,

    v_saldo_anterior,

    v_saldo_final,

    v_movimiento_caja_id;

end;
$$;


-- =============================================================
-- 2. SEGURIDAD
-- =============================================================

revoke all
on function
public.__drito_original_registrar_pago_cuenta_proveedor_08bf6aac1e(
  uuid,
  date,
  numeric,
  text,
  text,
  text
)
from public, anon, authenticated;


comment on function
public.__drito_original_registrar_pago_cuenta_proveedor_08bf6aac1e(
  uuid,
  date,
  numeric,
  text,
  text,
  text
)
is
  'DRITO_FUNCION_INTERNA_NO_RPC - Pago agrupado de proveedor usando saldo central dinero + retenciones practicadas.';


notify pgrst, 'reload schema';


commit;


-- =============================================================
-- FIN PASO 12B.2.4.1
-- =============================================================