-- =====================================================
-- DRITO - CUENTAS CORRIENTES DE CLIENTES
--
-- Las cuentas se calculan utilizando:
--   - ventas confirmadas
--   - pagos de ventas registrados
--
-- No se duplican movimientos en tablas adicionales.
-- =====================================================

-- =====================================================
-- ÍNDICES DE APOYO
-- =====================================================

create index if not exists
ventas_cuenta_corriente_cliente_idx
on public.ventas (
  comercio_id,
  cliente_id,
  fecha_venta desc,
  estado
);

create index if not exists
pagos_ventas_cuenta_corriente_idx
on public.pagos_ventas (
  venta_id,
  fecha_pago desc,
  estado
);

-- =====================================================
-- LISTADO GENERAL DE CUENTAS CORRIENTES
-- =====================================================

create or replace function
public.obtener_cuentas_corrientes_clientes(
  p_comercio_id uuid
)
returns table (
  cliente_id uuid,
  nombre_cliente text,
  telefono text,
  email text,
  activo boolean,

  total_ventas numeric,
  total_cobrado numeric,
  saldo_pendiente numeric,

  ventas_totales bigint,
  ventas_pendientes bigint,

  ultima_venta date,
  ultimo_pago date,
  ultima_actividad date
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  -- ===================================================
  -- VALIDACIONES
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
  -- CUENTAS DE CLIENTES
  -- ===================================================

  return query

  with ventas_resumen as (
    select
      v.cliente_id,

      coalesce(
        sum(v.total),
        0
      )::numeric as total_ventas,

      count(*)::bigint
        as ventas_totales,

      count(*) filter (
        where greatest(
          v.total
          - coalesce(
            v.total_pagado,
            0
          ),
          0
        ) > 0
      )::bigint
        as ventas_pendientes,

      max(v.fecha_venta)
        as ultima_venta

    from public.ventas as v

    where v.comercio_id =
      p_comercio_id

      and v.estado =
        'confirmada'

    group by
      v.cliente_id
  ),

  pagos_resumen as (
    select
      v.cliente_id,

      coalesce(
        sum(pv.importe),
        0
      )::numeric
        as total_cobrado,

      max(pv.fecha_pago)
        as ultimo_pago

    from public.pagos_ventas as pv

    inner join public.ventas as v
      on v.id = pv.venta_id

    where v.comercio_id =
      p_comercio_id

      and pv.estado =
        'registrado'

    group by
      v.cliente_id
  )

  select
    cl.id
      as cliente_id,

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
    ) as nombre_cliente,

    nullif(
      trim(
        coalesce(
          to_jsonb(cl)
            ->> 'telefono',
          ''
        )
      ),
      ''
    ) as telefono,

    nullif(
      trim(
        coalesce(
          to_jsonb(cl)
            ->> 'email',
          ''
        )
      ),
      ''
    ) as email,

    cl.activo,

    coalesce(
      vr.total_ventas,
      0
    )::numeric
      as total_ventas,

    coalesce(
      pr.total_cobrado,
      0
    )::numeric
      as total_cobrado,

    greatest(
      coalesce(
        vr.total_ventas,
        0
      )
      -
      coalesce(
        pr.total_cobrado,
        0
      ),
      0
    )::numeric
      as saldo_pendiente,

    coalesce(
      vr.ventas_totales,
      0
    )::bigint
      as ventas_totales,

    coalesce(
      vr.ventas_pendientes,
      0
    )::bigint
      as ventas_pendientes,

    vr.ultima_venta,

    pr.ultimo_pago,

    greatest(
      vr.ultima_venta,
      pr.ultimo_pago
    ) as ultima_actividad

  from public.clientes as cl

  left join ventas_resumen as vr
    on vr.cliente_id = cl.id

  left join pagos_resumen as pr
    on pr.cliente_id = cl.id

  where cl.comercio_id =
    p_comercio_id

  order by
    greatest(
      coalesce(
        vr.total_ventas,
        0
      )
      -
      coalesce(
        pr.total_cobrado,
        0
      ),
      0
    ) desc,

    nombre_cliente asc;
end;
$$;

-- =====================================================
-- DETALLE DE LA CUENTA CORRIENTE DE UN CLIENTE
-- =====================================================

create or replace function
public.obtener_cuenta_corriente_cliente(
  p_cliente_id uuid,
  p_fecha_desde date default null,
  p_fecha_hasta date default null
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_comercio_id uuid;

  v_nombre_cliente text;
  v_telefono text;
  v_email text;
  v_activo boolean;

  v_resultado jsonb;
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
    ),

    nullif(
      trim(
        coalesce(
          to_jsonb(cl)
            ->> 'telefono',
          ''
        )
      ),
      ''
    ),

    nullif(
      trim(
        coalesce(
          to_jsonb(cl)
            ->> 'email',
          ''
        )
      ),
      ''
    ),

    cl.activo

  into
    v_comercio_id,
    v_nombre_cliente,
    v_telefono,
    v_email,
    v_activo

  from public.clientes as cl

  where cl.id =
    p_cliente_id;

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
  -- RANGO DE FECHAS
  -- ===================================================

  if (
    p_fecha_desde is not null
    and p_fecha_hasta is not null
    and p_fecha_hasta < p_fecha_desde
  ) then
    raise exception
      'La fecha hasta no puede ser anterior a la fecha desde';
  end if;

  -- ===================================================
  -- MOVIMIENTOS
  -- ===================================================

  with movimientos_base as (
    -- ===============================================
    -- VENTAS
    -- ===============================================

    select
      v.id
        as movimiento_id,

      'venta'::text
        as tipo,

      v.fecha_venta
        as fecha,

      v.created_at,

      1::integer
        as prioridad,

      format(
        'VTA-%s',
        lpad(
          v.numero::text,
          6,
          '0'
        )
      ) as comprobante,

      format(
        'Venta VTA-%s',
        lpad(
          v.numero::text,
          6,
          '0'
        )
      ) as descripcion,

      v.total::numeric
        as importe,

      case
        when v.estado =
          'confirmada'
        then v.total
        else 0
      end::numeric
        as debe,

      0::numeric
        as haber,

      case
        when v.estado =
          'confirmada'
        then v.total
        else 0
      end::numeric
        as impacto,

      v.estado,

      v.id
        as venta_id,

      null::uuid
        as pago_id,

      null::text
        as medio_pago,

      null::text
        as referencia,

      v.observaciones

    from public.ventas as v

    where v.cliente_id =
      p_cliente_id

      and v.comercio_id =
        v_comercio_id

    union all

    -- ===============================================
    -- PAGOS
    -- ===============================================

    select
      pv.id
        as movimiento_id,

      'pago'::text
        as tipo,

      pv.fecha_pago
        as fecha,

      pv.created_at,

      2::integer
        as prioridad,

      format(
        'PAG-%s',
        lpad(
          pv.numero::text,
          6,
          '0'
        )
      ) as comprobante,

      format(
        'Cobro de venta VTA-%s',
        lpad(
          v.numero::text,
          6,
          '0'
        )
      ) as descripcion,

      pv.importe::numeric
        as importe,

      0::numeric
        as debe,

      case
        when pv.estado =
          'registrado'
        then pv.importe
        else 0
      end::numeric
        as haber,

      case
        when pv.estado =
          'registrado'
        then -pv.importe
        else 0
      end::numeric
        as impacto,

      pv.estado,

      pv.venta_id,

      pv.id
        as pago_id,

      pv.medio_pago,

      pv.referencia,

      pv.observaciones

    from public.pagos_ventas as pv

    inner join public.ventas as v
      on v.id = pv.venta_id

    where v.cliente_id =
      p_cliente_id

      and v.comercio_id =
        v_comercio_id
  ),

  saldo_previo as (
    select
      coalesce(
        sum(mb.impacto),
        0
      )::numeric
        as saldo_anterior

    from movimientos_base as mb

    where p_fecha_desde
      is not null

      and mb.fecha <
        p_fecha_desde
  ),

  movimientos_periodo as (
    select
      mb.*

    from movimientos_base as mb

    where (
      p_fecha_desde is null
      or mb.fecha >=
        p_fecha_desde
    )

    and (
      p_fecha_hasta is null
      or mb.fecha <=
        p_fecha_hasta
    )
  ),

  movimientos_con_saldo as (
    select
      mp.*,

      (
        sp.saldo_anterior
        +
        sum(
          mp.impacto
        ) over (
          order by
            mp.fecha asc,
            mp.created_at asc,
            mp.prioridad asc,
            mp.movimiento_id asc
        )
      )::numeric
        as saldo_acumulado

    from movimientos_periodo as mp

    cross join saldo_previo as sp
  ),

  resumen_global as (
    select
      coalesce(
        sum(
          case
            when mb.tipo = 'venta'
              and mb.estado =
                'confirmada'
            then mb.importe
            else 0
          end
        ),
        0
      )::numeric
        as total_ventas,

      coalesce(
        sum(
          case
            when mb.tipo = 'pago'
              and mb.estado =
                'registrado'
            then mb.importe
            else 0
          end
        ),
        0
      )::numeric
        as total_cobrado,

      coalesce(
        sum(mb.impacto),
        0
      )::numeric
        as saldo_actual,

      max(mb.fecha)
        as ultima_actividad

    from movimientos_base as mb
  ),

  resumen_periodo as (
    select
      coalesce(
        sum(mp.debe),
        0
      )::numeric
        as cargos_periodo,

      coalesce(
        sum(mp.haber),
        0
      )::numeric
        as pagos_periodo,

      count(*) filter (
        where mp.tipo =
          'venta'
      )::bigint
        as ventas_periodo,

      count(*) filter (
        where mp.tipo =
          'pago'

          and mp.estado =
            'registrado'
      )::bigint
        as pagos_registrados_periodo

    from movimientos_periodo as mp
  ),

  ventas_pendientes as (
    select
      count(*)::bigint
        as cantidad

    from public.ventas as v

    where v.cliente_id =
      p_cliente_id

      and v.comercio_id =
        v_comercio_id

      and v.estado =
        'confirmada'

      and greatest(
        v.total
        - coalesce(
          v.total_pagado,
          0
        ),
        0
      ) > 0
  )

  select
    jsonb_build_object(
      'cliente',
        jsonb_build_object(
          'id',
            p_cliente_id,

          'nombre',
            v_nombre_cliente,

          'telefono',
            v_telefono,

          'email',
            v_email,

          'activo',
            v_activo
        ),

      'periodo',
        jsonb_build_object(
          'fecha_desde',
            p_fecha_desde,

          'fecha_hasta',
            p_fecha_hasta
        ),

      'resumen',
        jsonb_build_object(
          'total_ventas',
            rg.total_ventas,

          'total_cobrado',
            rg.total_cobrado,

          'saldo_actual',
            greatest(
              rg.saldo_actual,
              0
            ),

          'ventas_pendientes',
            vp.cantidad,

          'ultima_actividad',
            rg.ultima_actividad
        ),

      'resumen_periodo',
        jsonb_build_object(
          'saldo_anterior',
            sp.saldo_anterior,

          'cargos',
            rp.cargos_periodo,

          'pagos',
            rp.pagos_periodo,

          'saldo_final',
            (
              sp.saldo_anterior
              +
              rp.cargos_periodo
              -
              rp.pagos_periodo
            ),

          'ventas',
            rp.ventas_periodo,

          'pagos_registrados',
            rp.pagos_registrados_periodo
        ),

      'movimientos',
        coalesce(
          (
            select
              jsonb_agg(
                jsonb_build_object(
                  'id',
                    mcs.movimiento_id,

                  'tipo',
                    mcs.tipo,

                  'fecha',
                    mcs.fecha,

                  'created_at',
                    mcs.created_at,

                  'comprobante',
                    mcs.comprobante,

                  'descripcion',
                    mcs.descripcion,

                  'importe',
                    mcs.importe,

                  'debe',
                    mcs.debe,

                  'haber',
                    mcs.haber,

                  'saldo',
                    mcs.saldo_acumulado,

                  'estado',
                    mcs.estado,

                  'venta_id',
                    mcs.venta_id,

                  'pago_id',
                    mcs.pago_id,

                  'medio_pago',
                    mcs.medio_pago,

                  'referencia',
                    mcs.referencia,

                  'observaciones',
                    mcs.observaciones
                )

                order by
                  mcs.fecha desc,
                  mcs.created_at desc,
                  mcs.prioridad desc,
                  mcs.movimiento_id desc
              )

            from movimientos_con_saldo
              as mcs
          ),

          '[]'::jsonb
        )
    )

  into v_resultado

  from resumen_global as rg

  cross join resumen_periodo as rp

  cross join saldo_previo as sp

  cross join ventas_pendientes as vp;

  return v_resultado;
end;
$$;

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on function
public.obtener_cuentas_corrientes_clientes(
  uuid
)
from public;

grant execute
on function
public.obtener_cuentas_corrientes_clientes(
  uuid
)
to authenticated;

revoke all
on function
public.obtener_cuenta_corriente_cliente(
  uuid,
  date,
  date
)
from public;

grant execute
on function
public.obtener_cuenta_corriente_cliente(
  uuid,
  date,
  date
)
to authenticated;

-- Actualizar la caché de PostgREST.

notify pgrst, 'reload schema';