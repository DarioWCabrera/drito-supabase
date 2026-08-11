-- =====================================================
-- DRITO - REPORTES FINANCIEROS
-- Archivo: 22_reportes_financieros.sql
--
-- Fuente principal: movimientos_caja vigentes.
-- Criterio: flujo de fondos (dinero efectivamente ingresado o egresado).
-- No representa por sí solo un estado contable o impositivo.
--
-- Incluye:
--   - Resumen del período
--   - Comparación con el período anterior equivalente
--   - Evolución diaria, semanal o mensual
--   - Ingresos y egresos por origen
--   - Gastos generales por categoría
--   - Distribución por medio de pago
--   - Últimos movimientos del período
-- =====================================================

-- =====================================================
-- ÍNDICES PARA CONSULTAS DE REPORTES
-- =====================================================

create index if not exists
movimientos_caja_reportes_idx
on public.movimientos_caja (
  comercio_id,
  estado,
  fecha,
  tipo
);

create index if not exists
gastos_generales_reportes_idx
on public.gastos_generales (
  comercio_id,
  estado,
  fecha_gasto,
  categoria_id
);

-- =====================================================
-- REPORTE FINANCIERO INTEGRAL
-- =====================================================

create or replace function
public.obtener_reporte_financiero(
  p_comercio_id uuid,
  p_fecha_desde date,
  p_fecha_hasta date,
  p_agrupacion text default 'dia'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agrupacion text;
  v_cantidad_dias integer;

  v_fecha_desde_anterior date;
  v_fecha_hasta_anterior date;

  v_inicio_serie date;
  v_fin_serie date;
  v_intervalo interval;

  v_resultado jsonb;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if p_comercio_id is null then
    raise exception 'El comercio es obligatorio';
  end if;

  if not public.pertenece_a_comercio(p_comercio_id) then
    raise exception
      'El usuario no pertenece al comercio indicado';
  end if;

  if p_fecha_desde is null or p_fecha_hasta is null then
    raise exception
      'Las fechas desde y hasta son obligatorias';
  end if;

  if p_fecha_hasta < p_fecha_desde then
    raise exception
      'La fecha hasta no puede ser anterior a la fecha desde';
  end if;

  v_agrupacion := lower(trim(coalesce(p_agrupacion, 'dia')));

  if v_agrupacion not in ('dia', 'semana', 'mes') then
    raise exception
      'La agrupación debe ser dia, semana o mes';
  end if;

  v_cantidad_dias :=
    (p_fecha_hasta - p_fecha_desde) + 1;

  v_fecha_hasta_anterior := p_fecha_desde - 1;
  v_fecha_desde_anterior :=
    v_fecha_hasta_anterior - (v_cantidad_dias - 1);

  if v_agrupacion = 'dia' then
    v_inicio_serie := p_fecha_desde;
    v_fin_serie := p_fecha_hasta;
    v_intervalo := interval '1 day';
  elsif v_agrupacion = 'semana' then
    v_inicio_serie :=
      date_trunc('week', p_fecha_desde::timestamp)::date;
    v_fin_serie :=
      date_trunc('week', p_fecha_hasta::timestamp)::date;
    v_intervalo := interval '1 week';
  else
    v_inicio_serie :=
      date_trunc('month', p_fecha_desde::timestamp)::date;
    v_fin_serie :=
      date_trunc('month', p_fecha_hasta::timestamp)::date;
    v_intervalo := interval '1 month';
  end if;

  with
  movimientos_actuales as (
    select mc.*
    from public.movimientos_caja as mc
    where mc.comercio_id = p_comercio_id
      and mc.fecha between p_fecha_desde and p_fecha_hasta
      and mc.estado = 'registrado'
  ),

  movimientos_anteriores as (
    select mc.*
    from public.movimientos_caja as mc
    where mc.comercio_id = p_comercio_id
      and mc.fecha between
        v_fecha_desde_anterior and v_fecha_hasta_anterior
      and mc.estado = 'registrado'
  ),

  resumen_actual as (
    select
      coalesce(
        sum(ma.importe) filter (where ma.tipo = 'ingreso'),
        0
      )::numeric(14,2) as ingresos,

      coalesce(
        sum(ma.importe) filter (where ma.tipo = 'egreso'),
        0
      )::numeric(14,2) as egresos,

      count(*) filter (where ma.tipo = 'ingreso')
        as cantidad_ingresos,

      count(*) filter (where ma.tipo = 'egreso')
        as cantidad_egresos,

      coalesce(
        avg(ma.importe) filter (where ma.tipo = 'ingreso'),
        0
      )::numeric(14,2) as promedio_ingreso,

      coalesce(
        avg(ma.importe) filter (where ma.tipo = 'egreso'),
        0
      )::numeric(14,2) as promedio_egreso,

      count(distinct ma.fecha) as dias_con_movimientos,

      coalesce(max(ma.importe) filter (where ma.tipo = 'ingreso'), 0)
        ::numeric(14,2) as mayor_ingreso,

      coalesce(max(ma.importe) filter (where ma.tipo = 'egreso'), 0)
        ::numeric(14,2) as mayor_egreso
    from movimientos_actuales as ma
  ),

  resumen_anterior as (
    select
      coalesce(
        sum(mp.importe) filter (where mp.tipo = 'ingreso'),
        0
      )::numeric(14,2) as ingresos,

      coalesce(
        sum(mp.importe) filter (where mp.tipo = 'egreso'),
        0
      )::numeric(14,2) as egresos
    from movimientos_anteriores as mp
  ),

  resumen_calculado as (
    select
      ra.ingresos,
      ra.egresos,
      (ra.ingresos - ra.egresos)::numeric(14,2)
        as resultado_neto,

      case
        when ra.ingresos > 0 then
          round(
            ((ra.ingresos - ra.egresos) / ra.ingresos) * 100,
            2
          )
        else 0
      end::numeric(10,2) as margen_resultado,

      ra.cantidad_ingresos,
      ra.cantidad_egresos,
      (ra.cantidad_ingresos + ra.cantidad_egresos)
        as cantidad_movimientos,
      ra.promedio_ingreso,
      ra.promedio_egreso,
      ra.dias_con_movimientos,
      ra.mayor_ingreso,
      ra.mayor_egreso,

      rp.ingresos as ingresos_anteriores,
      rp.egresos as egresos_anteriores,
      (rp.ingresos - rp.egresos)::numeric(14,2)
        as resultado_anterior
    from resumen_actual as ra
    cross join resumen_anterior as rp
  ),

  serie as (
    select gs::date as periodo
    from generate_series(
      v_inicio_serie::timestamp,
      v_fin_serie::timestamp,
      v_intervalo
    ) as gs
  ),

  movimientos_agrupados as (
    select
      case
        when v_agrupacion = 'dia' then ma.fecha
        when v_agrupacion = 'semana' then
          date_trunc('week', ma.fecha::timestamp)::date
        else
          date_trunc('month', ma.fecha::timestamp)::date
      end as periodo,

      coalesce(
        sum(ma.importe) filter (where ma.tipo = 'ingreso'),
        0
      )::numeric(14,2) as ingresos,

      coalesce(
        sum(ma.importe) filter (where ma.tipo = 'egreso'),
        0
      )::numeric(14,2) as egresos,

      count(*) filter (where ma.tipo = 'ingreso')
        as cantidad_ingresos,

      count(*) filter (where ma.tipo = 'egreso')
        as cantidad_egresos
    from movimientos_actuales as ma
    group by 1
  ),

  evolucion_base as (
    select
      s.periodo,

      case
        when v_agrupacion = 'dia' then s.periodo
        when v_agrupacion = 'semana' then
          least(s.periodo + 6, p_fecha_hasta)
        else
          least(
            (s.periodo + interval '1 month - 1 day')::date,
            p_fecha_hasta
          )
      end as periodo_hasta,

      case
        when v_agrupacion = 'dia' then
          to_char(s.periodo, 'DD/MM')
        when v_agrupacion = 'semana' then
          'Sem. ' || to_char(s.periodo, 'DD/MM')
        else
          to_char(s.periodo, 'MM/YYYY')
      end as etiqueta,

      coalesce(ma.ingresos, 0)::numeric(14,2) as ingresos,
      coalesce(ma.egresos, 0)::numeric(14,2) as egresos,
      (
        coalesce(ma.ingresos, 0)
        - coalesce(ma.egresos, 0)
      )::numeric(14,2) as resultado,
      coalesce(ma.cantidad_ingresos, 0) as cantidad_ingresos,
      coalesce(ma.cantidad_egresos, 0) as cantidad_egresos
    from serie as s
    left join movimientos_agrupados as ma
      on ma.periodo = s.periodo
    order by s.periodo
  ),

  evolucion as (
    select
      eb.*,
      sum(eb.resultado) over (
        order by eb.periodo
        rows between unbounded preceding and current row
      )::numeric(14,2) as saldo_acumulado
    from evolucion_base as eb
  ),

  origenes as (
    select
      ma.tipo,
      case
        when ma.gasto_general_id is not null then
          'Gastos generales'
        when ma.pago_proveedor_id is not null then
          'Pagos a proveedores'
        when lower(coalesce(ma.origen, '')) = 'compra' then
          'Pagos de compras'
        when lower(coalesce(ma.origen, '')) = 'venta' then
          'Cobros de ventas'
        when lower(coalesce(ma.origen, '')) = 'manual' then
          'Movimientos manuales'
        when nullif(trim(coalesce(ma.origen, '')), '') is null then
          'Sin origen'
        else
          initcap(replace(ma.origen, '_', ' '))
      end as origen,
      sum(ma.importe)::numeric(14,2) as importe,
      count(*) as cantidad
    from movimientos_actuales as ma
    group by 1, 2
  ),

  gastos_categoria as (
    select
      cg.id as categoria_id,
      cg.nombre as categoria,
      sum(gg.importe)::numeric(14,2) as importe,
      count(*) as cantidad
    from public.gastos_generales as gg
    inner join public.categorias_gastos as cg
      on cg.id = gg.categoria_id
    where gg.comercio_id = p_comercio_id
      and gg.fecha_gasto between p_fecha_desde and p_fecha_hasta
      and gg.estado = 'registrado'
    group by cg.id, cg.nombre
  ),

  total_gastos_categoria as (
    select coalesce(sum(gc.importe), 0)::numeric(14,2) as total
    from gastos_categoria as gc
  ),

  medios_pago as (
    select
      coalesce(
        nullif(trim(ma.medio_pago), ''),
        'Sin especificar'
      ) as medio_pago,
      ma.tipo,
      sum(ma.importe)::numeric(14,2) as importe,
      count(*) as cantidad
    from movimientos_actuales as ma
    group by 1, 2
  ),

  ultimos_movimientos as (
    select
      ma.id,
      ma.fecha,
      ma.tipo,
      ma.importe,
      ma.concepto,
      ma.medio_pago,
      ma.referencia,
      ma.origen,
      ma.created_at,
      cg.nombre as categoria_gasto
    from movimientos_actuales as ma
    left join public.gastos_generales as gg
      on gg.id = ma.gasto_general_id
    left join public.categorias_gastos as cg
      on cg.id = gg.categoria_id
    order by ma.fecha desc, ma.created_at desc
    limit 12
  )

  select jsonb_build_object(
    'periodo', jsonb_build_object(
      'fecha_desde', p_fecha_desde,
      'fecha_hasta', p_fecha_hasta,
      'agrupacion', v_agrupacion,
      'cantidad_dias', v_cantidad_dias,
      'fecha_desde_anterior', v_fecha_desde_anterior,
      'fecha_hasta_anterior', v_fecha_hasta_anterior
    ),

    'resumen', (
      select jsonb_build_object(
        'ingresos', rc.ingresos,
        'egresos', rc.egresos,
        'resultado_neto', rc.resultado_neto,
        'margen_resultado', rc.margen_resultado,
        'cantidad_ingresos', rc.cantidad_ingresos,
        'cantidad_egresos', rc.cantidad_egresos,
        'cantidad_movimientos', rc.cantidad_movimientos,
        'promedio_ingreso', rc.promedio_ingreso,
        'promedio_egreso', rc.promedio_egreso,
        'dias_con_movimientos', rc.dias_con_movimientos,
        'mayor_ingreso', rc.mayor_ingreso,
        'mayor_egreso', rc.mayor_egreso
      )
      from resumen_calculado as rc
    ),

    'comparacion', (
      select jsonb_build_object(
        'ingresos_anteriores', rc.ingresos_anteriores,
        'egresos_anteriores', rc.egresos_anteriores,
        'resultado_anterior', rc.resultado_anterior,

        'variacion_ingresos',
          case
            when rc.ingresos_anteriores = 0 then null
            else round(
              (
                (rc.ingresos - rc.ingresos_anteriores)
                / abs(rc.ingresos_anteriores)
              ) * 100,
              2
            )
          end,

        'variacion_egresos',
          case
            when rc.egresos_anteriores = 0 then null
            else round(
              (
                (rc.egresos - rc.egresos_anteriores)
                / abs(rc.egresos_anteriores)
              ) * 100,
              2
            )
          end,

        'variacion_resultado',
          case
            when rc.resultado_anterior = 0 then null
            else round(
              (
                (rc.resultado_neto - rc.resultado_anterior)
                / abs(rc.resultado_anterior)
              ) * 100,
              2
            )
          end
      )
      from resumen_calculado as rc
    ),

    'evolucion', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'periodo', e.periodo,
            'periodo_hasta', e.periodo_hasta,
            'etiqueta', e.etiqueta,
            'ingresos', e.ingresos,
            'egresos', e.egresos,
            'resultado', e.resultado,
            'saldo_acumulado', e.saldo_acumulado,
            'cantidad_ingresos', e.cantidad_ingresos,
            'cantidad_egresos', e.cantidad_egresos
          )
          order by e.periodo
        )
        from evolucion as e
      ),
      '[]'::jsonb
    ),

    'ingresos_por_origen', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'origen', o.origen,
            'importe', o.importe,
            'cantidad', o.cantidad,
            'porcentaje',
              case
                when rc.ingresos > 0 then
                  round((o.importe / rc.ingresos) * 100, 2)
                else 0
              end
          )
          order by o.importe desc, o.origen
        )
        from origenes as o
        cross join resumen_calculado as rc
        where o.tipo = 'ingreso'
      ),
      '[]'::jsonb
    ),

    'egresos_por_origen', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'origen', o.origen,
            'importe', o.importe,
            'cantidad', o.cantidad,
            'porcentaje',
              case
                when rc.egresos > 0 then
                  round((o.importe / rc.egresos) * 100, 2)
                else 0
              end
          )
          order by o.importe desc, o.origen
        )
        from origenes as o
        cross join resumen_calculado as rc
        where o.tipo = 'egreso'
      ),
      '[]'::jsonb
    ),

    'gastos_por_categoria', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'categoria_id', gc.categoria_id,
            'categoria', gc.categoria,
            'importe', gc.importe,
            'cantidad', gc.cantidad,
            'porcentaje',
              case
                when tgc.total > 0 then
                  round((gc.importe / tgc.total) * 100, 2)
                else 0
              end
          )
          order by gc.importe desc, gc.categoria
        )
        from gastos_categoria as gc
        cross join total_gastos_categoria as tgc
      ),
      '[]'::jsonb
    ),

    'medios_pago', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'medio_pago', mp.medio_pago,
            'tipo', mp.tipo,
            'importe', mp.importe,
            'cantidad', mp.cantidad
          )
          order by mp.tipo, mp.importe desc, mp.medio_pago
        )
        from medios_pago as mp
      ),
      '[]'::jsonb
    ),

    'ultimos_movimientos', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', um.id,
            'fecha', um.fecha,
            'tipo', um.tipo,
            'importe', um.importe,
            'concepto', um.concepto,
            'medio_pago', um.medio_pago,
            'referencia', um.referencia,
            'origen', um.origen,
            'categoria_gasto', um.categoria_gasto,
            'created_at', um.created_at
          )
          order by um.fecha desc, um.created_at desc
        )
        from ultimos_movimientos as um
      ),
      '[]'::jsonb
    )
  )
  into v_resultado;

  return v_resultado;
end;
$$;

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all on function
public.obtener_reporte_financiero(
  uuid,
  date,
  date,
  text
)
from public, anon, authenticated;

grant execute on function
public.obtener_reporte_financiero(
  uuid,
  date,
  date,
  text
)
to authenticated;

-- =====================================================
-- VERIFICACIÓN
-- =====================================================

select
  p.proname as funcion,
  pg_get_function_identity_arguments(p.oid) as argumentos
from pg_proc as p
inner join pg_namespace as n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'obtener_reporte_financiero';

-- Ejemplo para probar desde SQL Editor con un comercio real:
--
-- select public.obtener_reporte_financiero(
--   'UUID-DEL-COMERCIO'::uuid,
--   date_trunc('month', current_date)::date,
--   current_date,
--   'dia'
-- );

-- =====================================================
-- FIN DEL MÓDULO
-- =====================================================