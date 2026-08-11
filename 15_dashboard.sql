-- =====================================================
-- DRITO - DASHBOARD REAL
-- RESUMEN GENERAL DEL COMERCIO
-- =====================================================

-- =====================================================
-- ÍNDICES DE APOYO
-- =====================================================

create index if not exists
ventas_dashboard_fecha_idx
on public.ventas (
  comercio_id,
  fecha_venta,
  estado
);

create index if not exists
compras_dashboard_fecha_idx
on public.compras (
  comercio_id,
  fecha_compra,
  estado
);

create index if not exists
compras_dashboard_vencimiento_idx
on public.compras (
  comercio_id,
  fecha_vencimiento,
  estado_pago
)
where fecha_vencimiento is not null;

create index if not exists
productos_dashboard_stock_idx
on public.productos (
  comercio_id,
  activo,
  controla_stock,
  stock_actual,
  stock_minimo
);

-- =====================================================
-- OBTENER DASHBOARD DEL COMERCIO
-- =====================================================

create or replace function
public.obtener_dashboard_comercio(
  p_comercio_id uuid,
  p_fecha_referencia date default current_date
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_inicio_mes date;
  v_fin_mes date;

  v_inicio_ultimos_7_dias date;

  v_resultado jsonb;
begin
  -- ===================================================
  -- AUTENTICACIÓN Y COMERCIO
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

  if p_fecha_referencia is null then
    raise exception
      'La fecha de referencia es obligatoria';
  end if;

  -- ===================================================
  -- PERÍODOS
  -- ===================================================

  v_inicio_mes :=
    date_trunc(
      'month',
      p_fecha_referencia
    )::date;

  v_fin_mes :=
    (
      date_trunc(
        'month',
        p_fecha_referencia
      )
      + interval '1 month'
      - interval '1 day'
    )::date;

  v_inicio_ultimos_7_dias :=
    p_fecha_referencia - 6;

  -- ===================================================
  -- CONSTRUIR RESPUESTA
  -- ===================================================

  with metricas as (
    select
      -- ===============================================
      -- VENTAS
      -- ===============================================

      coalesce(
        (
          select sum(v.total)
          from public.ventas as v
          where v.comercio_id =
            p_comercio_id
            and v.estado = 'confirmada'
            and v.fecha_venta =
              p_fecha_referencia
        ),
        0
      )::numeric as ventas_hoy,

      coalesce(
        (
          select count(*)
          from public.ventas as v
          where v.comercio_id =
            p_comercio_id
            and v.estado = 'confirmada'
            and v.fecha_venta =
              p_fecha_referencia
        ),
        0
      )::bigint as ventas_hoy_cantidad,

      coalesce(
        (
          select sum(v.total)
          from public.ventas as v
          where v.comercio_id =
            p_comercio_id
            and v.estado = 'confirmada'
            and v.fecha_venta between
              v_inicio_mes
              and p_fecha_referencia
        ),
        0
      )::numeric as ventas_mes,

      coalesce(
        (
          select count(*)
          from public.ventas as v
          where v.comercio_id =
            p_comercio_id
            and v.estado = 'confirmada'
            and v.fecha_venta between
              v_inicio_mes
              and p_fecha_referencia
        ),
        0
      )::bigint as ventas_mes_cantidad,

      -- ===============================================
      -- COBROS DE VENTAS
      -- ===============================================

      coalesce(
        (
          select sum(mc.importe)
          from public.movimientos_caja as mc
          where mc.comercio_id =
            p_comercio_id
            and mc.estado = 'registrado'
            and mc.tipo = 'ingreso'
            and mc.origen = 'venta'
            and mc.fecha between
              v_inicio_mes
              and p_fecha_referencia
        ),
        0
      )::numeric as cobros_mes,

      -- ===============================================
      -- COMPRAS
      -- ===============================================

      coalesce(
        (
          select sum(c.total)
          from public.compras as c
          where c.comercio_id =
            p_comercio_id
            and c.estado = 'confirmada'
            and c.fecha_compra between
              v_inicio_mes
              and p_fecha_referencia
        ),
        0
      )::numeric as compras_mes,

      coalesce(
        (
          select count(*)
          from public.compras as c
          where c.comercio_id =
            p_comercio_id
            and c.estado = 'confirmada'
            and c.fecha_compra between
              v_inicio_mes
              and p_fecha_referencia
        ),
        0
      )::bigint as compras_mes_cantidad,

      -- ===============================================
      -- PAGOS A PROVEEDORES
      -- ===============================================

      coalesce(
        (
          select sum(mc.importe)
          from public.movimientos_caja as mc
          where mc.comercio_id =
            p_comercio_id
            and mc.estado = 'registrado'
            and mc.tipo = 'egreso'
            and mc.origen = 'compra'
            and mc.fecha between
              v_inicio_mes
              and p_fecha_referencia
        ),
        0
      )::numeric as pagos_proveedores_mes,

      -- ===============================================
      -- CAJA DEL MES
      -- ===============================================

      coalesce(
        (
          select sum(mc.importe)
          from public.movimientos_caja as mc
          where mc.comercio_id =
            p_comercio_id
            and mc.estado = 'registrado'
            and mc.tipo = 'ingreso'
            and mc.fecha between
              v_inicio_mes
              and p_fecha_referencia
        ),
        0
      )::numeric as ingresos_caja_mes,

      coalesce(
        (
          select sum(mc.importe)
          from public.movimientos_caja as mc
          where mc.comercio_id =
            p_comercio_id
            and mc.estado = 'registrado'
            and mc.tipo = 'egreso'
            and mc.fecha between
              v_inicio_mes
              and p_fecha_referencia
        ),
        0
      )::numeric as egresos_caja_mes,

      -- ===============================================
      -- CUENTAS POR COBRAR
      -- ===============================================

      coalesce(
        (
          select sum(
            greatest(
              v.total
              - coalesce(
                v.total_pagado,
                0
              ),
              0
            )
          )
          from public.ventas as v
          where v.comercio_id =
            p_comercio_id
            and v.estado = 'confirmada'
            and greatest(
              v.total
              - coalesce(
                v.total_pagado,
                0
              ),
              0
            ) > 0
        ),
        0
      )::numeric as cuentas_por_cobrar,

      coalesce(
        (
          select count(*)
          from public.ventas as v
          where v.comercio_id =
            p_comercio_id
            and v.estado = 'confirmada'
            and greatest(
              v.total
              - coalesce(
                v.total_pagado,
                0
              ),
              0
            ) > 0
        ),
        0
      )::bigint as ventas_pendientes_cobro,

      -- ===============================================
      -- CUENTAS POR PAGAR
      -- ===============================================

      coalesce(
        (
          select sum(
            greatest(
              c.total
              - coalesce(
                c.total_pagado,
                0
              ),
              0
            )
          )
          from public.compras as c
          where c.comercio_id =
            p_comercio_id
            and c.estado = 'confirmada'
            and greatest(
              c.total
              - coalesce(
                c.total_pagado,
                0
              ),
              0
            ) > 0
        ),
        0
      )::numeric as cuentas_por_pagar,

      coalesce(
        (
          select count(*)
          from public.compras as c
          where c.comercio_id =
            p_comercio_id
            and c.estado = 'confirmada'
            and greatest(
              c.total
              - coalesce(
                c.total_pagado,
                0
              ),
              0
            ) > 0
        ),
        0
      )::bigint as compras_pendientes_pago,

      -- ===============================================
      -- STOCK
      -- ===============================================

      coalesce(
        (
          select sum(
            coalesce(
              p.stock_actual,
              0
            )
            *
            coalesce(
              p.costo,
              0
            )
          )
          from public.productos as p
          where p.comercio_id =
            p_comercio_id
            and p.activo = true
            and p.tipo = 'producto'
            and p.controla_stock = true
        ),
        0
      )::numeric as stock_valorizado,

      coalesce(
        (
          select count(*)
          from public.productos as p
          where p.comercio_id =
            p_comercio_id
            and p.activo = true
            and p.tipo = 'producto'
            and p.controla_stock = true
            and coalesce(
              p.stock_actual,
              0
            ) <= coalesce(
              p.stock_minimo,
              0
            )
        ),
        0
      )::bigint as productos_stock_bajo,

      coalesce(
        (
          select count(*)
          from public.productos as p
          where p.comercio_id =
            p_comercio_id
            and p.activo = true
            and p.tipo = 'producto'
            and p.controla_stock = true
            and coalesce(
              p.stock_actual,
              0
            ) <= 0
        ),
        0
      )::bigint as productos_sin_stock,

      -- ===============================================
      -- ENTIDADES
      -- ===============================================

      coalesce(
        (
          select count(*)
          from public.clientes as cl
          where cl.comercio_id =
            p_comercio_id
            and cl.activo = true
        ),
        0
      )::bigint as clientes_activos,

      coalesce(
        (
          select count(*)
          from public.proveedores as pr
          where pr.comercio_id =
            p_comercio_id
            and pr.activo = true
        ),
        0
      )::bigint as proveedores_activos
  ),

  dias as (
    select
      generate_series(
        v_inicio_ultimos_7_dias,
        p_fecha_referencia,
        interval '1 day'
      )::date as fecha
  ),

  ventas_por_dia as (
    select
      d.fecha,

      coalesce(
        sum(v.total),
        0
      )::numeric as total,

      count(v.id)::bigint as cantidad

    from dias as d

    left join public.ventas as v
      on v.comercio_id =
        p_comercio_id
      and v.estado = 'confirmada'
      and v.fecha_venta = d.fecha

    group by d.fecha
    order by d.fecha
  ),

  stock_bajo as (
    select
      p.id,
      p.nombre,
      p.codigo,

      coalesce(
        p.stock_actual,
        0
      )::numeric as stock_actual,

      coalesce(
        p.stock_minimo,
        0
      )::numeric as stock_minimo,

      coalesce(
        p.unidad_medida,
        'unidad'
      ) as unidad_medida

    from public.productos as p

    where p.comercio_id =
      p_comercio_id
      and p.activo = true
      and p.tipo = 'producto'
      and p.controla_stock = true
      and coalesce(
        p.stock_actual,
        0
      ) <= coalesce(
        p.stock_minimo,
        0
      )

    order by
      case
        when coalesce(
          p.stock_actual,
          0
        ) <= 0
        then 0
        else 1
      end,

      coalesce(
        p.stock_actual,
        0
      ) asc,

      p.nombre asc

    limit 6
  ),

  compras_por_vencer as (
    select
      c.id,
      c.numero,
      c.fecha_vencimiento,

      greatest(
        c.total
        - coalesce(
          c.total_pagado,
          0
        ),
        0
      )::numeric as saldo_pendiente,

      (
        c.fecha_vencimiento
        - p_fecha_referencia
      )::integer as dias_para_vencer,

      coalesce(
        nullif(
          trim(pr.razon_social),
          ''
        ),

        nullif(
          trim(pr.nombre),
          ''
        ),

        'Proveedor no disponible'
      ) as proveedor

    from public.compras as c

    left join public.proveedores as pr
      on pr.id = c.proveedor_id

    where c.comercio_id =
      p_comercio_id
      and c.estado = 'confirmada'
      and c.fecha_vencimiento is not null
      and greatest(
        c.total
        - coalesce(
          c.total_pagado,
          0
        ),
        0
      ) > 0
      and c.fecha_vencimiento <=
        p_fecha_referencia + 7

    order by
      c.fecha_vencimiento asc,
      c.numero asc

    limit 6
  ),

  ultimos_movimientos as (
    select
      mc.id,
      mc.fecha,
      mc.tipo,
      mc.origen,
      mc.concepto,
      mc.referencia,
      mc.importe,
      mc.medio_pago,
      mc.created_at

    from public.movimientos_caja as mc

    where mc.comercio_id =
      p_comercio_id
      and mc.estado = 'registrado'

    order by
      mc.fecha desc,
      mc.created_at desc

    limit 8
  )

  select jsonb_build_object(
    'fecha_referencia',
      p_fecha_referencia,

    'periodo',
      jsonb_build_object(
        'inicio_mes',
          v_inicio_mes,

        'fin_mes',
          v_fin_mes
      ),

    'metricas',
      jsonb_build_object(
        'ventas_hoy',
          m.ventas_hoy,

        'ventas_hoy_cantidad',
          m.ventas_hoy_cantidad,

        'ventas_mes',
          m.ventas_mes,

        'ventas_mes_cantidad',
          m.ventas_mes_cantidad,

        'cobros_mes',
          m.cobros_mes,

        'compras_mes',
          m.compras_mes,

        'compras_mes_cantidad',
          m.compras_mes_cantidad,

        'pagos_proveedores_mes',
          m.pagos_proveedores_mes,

        'ingresos_caja_mes',
          m.ingresos_caja_mes,

        'egresos_caja_mes',
          m.egresos_caja_mes,

        'saldo_caja_mes',
          (
            m.ingresos_caja_mes
            - m.egresos_caja_mes
          ),

        'cuentas_por_cobrar',
          m.cuentas_por_cobrar,

        'ventas_pendientes_cobro',
          m.ventas_pendientes_cobro,

        'cuentas_por_pagar',
          m.cuentas_por_pagar,

        'compras_pendientes_pago',
          m.compras_pendientes_pago,

        'stock_valorizado',
          m.stock_valorizado,

        'productos_stock_bajo',
          m.productos_stock_bajo,

        'productos_sin_stock',
          m.productos_sin_stock,

        'clientes_activos',
          m.clientes_activos,

        'proveedores_activos',
          m.proveedores_activos
      ),

    'ventas_ultimos_7_dias',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'fecha',
                vpd.fecha,

              'total',
                vpd.total,

              'cantidad',
                vpd.cantidad
            )
            order by vpd.fecha
          )
          from ventas_por_dia as vpd
        ),
        '[]'::jsonb
      ),

    'stock_bajo',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id',
                sb.id,

              'nombre',
                sb.nombre,

              'codigo',
                sb.codigo,

              'stock_actual',
                sb.stock_actual,

              'stock_minimo',
                sb.stock_minimo,

              'unidad_medida',
                sb.unidad_medida
            )
            order by
              sb.stock_actual asc,
              sb.nombre asc
          )
          from stock_bajo as sb
        ),
        '[]'::jsonb
      ),

    'compras_por_vencer',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id',
                cpv.id,

              'numero',
                cpv.numero,

              'proveedor',
                cpv.proveedor,

              'fecha_vencimiento',
                cpv.fecha_vencimiento,

              'saldo_pendiente',
                cpv.saldo_pendiente,

              'dias_para_vencer',
                cpv.dias_para_vencer
            )
            order by
              cpv.fecha_vencimiento asc,
              cpv.numero asc
          )
          from compras_por_vencer as cpv
        ),
        '[]'::jsonb
      ),

    'ultimos_movimientos',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id',
                um.id,

              'fecha',
                um.fecha,

              'tipo',
                um.tipo,

              'origen',
                um.origen,

              'concepto',
                um.concepto,

              'referencia',
                um.referencia,

              'importe',
                um.importe,

              'medio_pago',
                um.medio_pago,

              'created_at',
                um.created_at
            )
            order by
              um.fecha desc,
              um.created_at desc
          )
          from ultimos_movimientos as um
        ),
        '[]'::jsonb
      )
  )
  into v_resultado
  from metricas as m;

  return v_resultado;
end;
$$;

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on function
public.obtener_dashboard_comercio(
  uuid,
  date
)
from public;

grant execute
on function
public.obtener_dashboard_comercio(
  uuid,
  date
)
to authenticated;