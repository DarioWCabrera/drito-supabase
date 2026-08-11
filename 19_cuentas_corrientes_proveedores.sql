-- =====================================================
-- DRITO - CUENTAS CORRIENTES DE PROVEEDORES
--
-- Fuente de verdad:
--   compras        -> aumenta la deuda
--   pagos_compras  -> disminuye la deuda
--
-- No crea una tabla duplicada de movimientos.
-- La cuenta corriente se calcula desde los documentos
-- comerciales ya existentes.
-- =====================================================

-- =====================================================
-- ÍNDICES DE CONSULTA
-- =====================================================

create index if not exists
compras_cuenta_corriente_proveedor_idx
on public.compras (
  comercio_id,
  proveedor_id,
  estado,
  fecha_compra desc
);

create index if not exists
pagos_compras_cuenta_corriente_idx
on public.pagos_compras (
  compra_id,
  estado,
  fecha_pago desc
);

-- =====================================================
-- RESUMEN GENERAL DE CUENTAS DE PROVEEDORES
-- =====================================================

drop function if exists
public.obtener_cuentas_corrientes_proveedores(uuid);

create or replace function
public.obtener_cuentas_corrientes_proveedores(
  p_comercio_id uuid
)
returns table (
  proveedor_id uuid,
  nombre_proveedor text,
  telefono text,
  email text,
  activo boolean,

  total_compras numeric,
  total_pagado numeric,
  saldo_pendiente numeric,

  compras_totales bigint,
  compras_pendientes bigint,

  proxima_fecha_vencimiento date,

  ultima_compra date,
  ultimo_pago date,
  ultima_actividad date
)
language plpgsql
security definer
set search_path = public
as $$
begin
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

  return query

  with pagos_por_compra as (
    select
      pc.compra_id,

      coalesce(
        sum(pc.importe)
          filter (
            where pc.estado = 'registrado'
          ),
        0
      )::numeric(14,2)
        as importe_pagado,

      max(pc.fecha_pago)
        filter (
          where pc.estado = 'registrado'
        )
        as ultimo_pago

    from public.pagos_compras as pc

    inner join public.compras as c
      on c.id = pc.compra_id

    where c.comercio_id =
      p_comercio_id

    group by
      pc.compra_id
  ),

  compras_detalle as (
    select
      c.id,
      c.proveedor_id,
      c.fecha_compra,
      c.numero,

      c.total::numeric(14,2)
        as total,

      coalesce(
        ppc.importe_pagado,
        0
      )::numeric(14,2)
        as importe_pagado,

      greatest(
        c.total
        -
        coalesce(
          ppc.importe_pagado,
          0
        ),
        0
      )::numeric(14,2)
        as saldo_pendiente,

      case
        when
          coalesce(
            to_jsonb(c)
              ->> 'fecha_vencimiento',
            ''
          )
          ~ '^\d{4}-\d{2}-\d{2}$'
        then
          (
            to_jsonb(c)
              ->> 'fecha_vencimiento'
          )::date
        else null
      end
        as fecha_vencimiento,

      ppc.ultimo_pago

    from public.compras as c

    left join pagos_por_compra
      as ppc
      on ppc.compra_id =
        c.id

    where c.comercio_id =
      p_comercio_id

      and c.estado =
        'confirmada'
  ),

  resumen_compras as (
    select
      cd.proveedor_id,

      coalesce(
        sum(cd.total),
        0
      )::numeric(14,2)
        as total_compras,

      coalesce(
        sum(cd.importe_pagado),
        0
      )::numeric(14,2)
        as total_pagado,

      coalesce(
        sum(cd.saldo_pendiente),
        0
      )::numeric(14,2)
        as saldo_pendiente,

      count(*)::bigint
        as compras_totales,

      count(*)
        filter (
          where cd.saldo_pendiente > 0
        )::bigint
        as compras_pendientes,

      min(cd.fecha_vencimiento)
        filter (
          where
            cd.saldo_pendiente > 0
            and cd.fecha_vencimiento
              is not null
        )
        as proxima_fecha_vencimiento,

      max(cd.fecha_compra)
        as ultima_compra,

      max(cd.ultimo_pago)
        as ultimo_pago

    from compras_detalle as cd

    group by
      cd.proveedor_id
  )

  select
    pr.id
      as proveedor_id,

    coalesce(
      nullif(
        trim(
          to_jsonb(pr)
            ->> 'razon_social'
        ),
        ''
      ),

      nullif(
        trim(
          to_jsonb(pr)
            ->> 'nombre'
        ),
        ''
      ),

      nullif(
        trim(
          to_jsonb(pr)
            ->> 'nombre_fantasia'
        ),
        ''
      ),

      'Proveedor sin nombre'
    )
      as nombre_proveedor,

    nullif(
      trim(
        coalesce(
          to_jsonb(pr)
            ->> 'telefono',
          ''
        )
      ),
      ''
    )
      as telefono,

    nullif(
      trim(
        coalesce(
          to_jsonb(pr)
            ->> 'email',
          ''
        )
      ),
      ''
    )
      as email,

    coalesce(
      nullif(
        to_jsonb(pr)
          ->> 'activo',
        ''
      )::boolean,
      true
    )
      as activo,

    coalesce(
      rc.total_compras,
      0
    )::numeric(14,2)
      as total_compras,

    coalesce(
      rc.total_pagado,
      0
    )::numeric(14,2)
      as total_pagado,

    coalesce(
      rc.saldo_pendiente,
      0
    )::numeric(14,2)
      as saldo_pendiente,

    coalesce(
      rc.compras_totales,
      0
    )::bigint
      as compras_totales,

    coalesce(
      rc.compras_pendientes,
      0
    )::bigint
      as compras_pendientes,

    rc.proxima_fecha_vencimiento,

    rc.ultima_compra,
    rc.ultimo_pago,

    case
      when
        rc.ultima_compra is null
        and rc.ultimo_pago is null
      then null

      when rc.ultima_compra is null
      then rc.ultimo_pago

      when rc.ultimo_pago is null
      then rc.ultima_compra

      else greatest(
        rc.ultima_compra,
        rc.ultimo_pago
      )
    end
      as ultima_actividad

  from public.proveedores as pr

  left join resumen_compras
    as rc
    on rc.proveedor_id =
      pr.id

  where pr.comercio_id =
    p_comercio_id

  order by
    coalesce(
      rc.saldo_pendiente,
      0
    ) desc,

    2 asc;
end;
$$;

-- =====================================================
-- EXTRACTO DE UN PROVEEDOR
--
-- Devuelve:
--   proveedor
--   período consultado
--   resumen general
--   resumen del período
--   movimientos cronológicos con saldo acumulado
--
-- Las compras anuladas y los pagos anulados se conservan
-- en el extracto, pero su impacto contable es cero.
-- =====================================================

drop function if exists
public.obtener_cuenta_corriente_proveedor(
  uuid,
  date,
  date
);

create or replace function
public.obtener_cuenta_corriente_proveedor(
  p_proveedor_id uuid,
  p_fecha_desde date default null,
  p_fecha_hasta date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comercio_id uuid;

  v_nombre_proveedor text;
  v_telefono text;
  v_email text;
  v_activo boolean;

  v_total_compras numeric(14,2) :=
    0;

  v_total_pagado numeric(14,2) :=
    0;

  v_saldo_actual numeric(14,2) :=
    0;

  v_compras_totales bigint :=
    0;

  v_compras_pendientes bigint :=
    0;

  v_ultima_compra date;
  v_ultimo_pago date;
  v_ultima_actividad date;

  v_saldo_anterior numeric(14,2) :=
    0;

  v_cargos_periodo numeric(14,2) :=
    0;

  v_pagos_periodo numeric(14,2) :=
    0;

  v_saldo_final numeric(14,2) :=
    0;

  v_movimientos jsonb :=
    '[]'::jsonb;
begin
  -- ===================================================
  -- AUTENTICACIÓN Y PROVEEDOR
  -- ===================================================

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;

  if p_proveedor_id is null then
    raise exception
      'El proveedor es obligatorio';
  end if;

  if (
    p_fecha_desde is not null
    and p_fecha_hasta is not null
    and p_fecha_hasta <
      p_fecha_desde
  ) then
    raise exception
      'La fecha hasta no puede ser anterior a la fecha desde';
  end if;

  select
    pr.comercio_id,

    coalesce(
      nullif(
        trim(
          to_jsonb(pr)
            ->> 'razon_social'
        ),
        ''
      ),

      nullif(
        trim(
          to_jsonb(pr)
            ->> 'nombre'
        ),
        ''
      ),

      nullif(
        trim(
          to_jsonb(pr)
            ->> 'nombre_fantasia'
        ),
        ''
      ),

      'Proveedor sin nombre'
    ),

    nullif(
      trim(
        coalesce(
          to_jsonb(pr)
            ->> 'telefono',
          ''
        )
      ),
      ''
    ),

    nullif(
      trim(
        coalesce(
          to_jsonb(pr)
            ->> 'email',
          ''
        )
      ),
      ''
    ),

    coalesce(
      nullif(
        to_jsonb(pr)
          ->> 'activo',
        ''
      )::boolean,
      true
    )

  into
    v_comercio_id,
    v_nombre_proveedor,
    v_telefono,
    v_email,
    v_activo

  from public.proveedores as pr

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

  -- ===================================================
  -- RESUMEN GENERAL
  -- ===================================================

  select
    coalesce(
      sum(c.total)
        filter (
          where c.estado =
            'confirmada'
        ),
      0
    )::numeric(14,2),

    count(*)
      filter (
        where c.estado =
          'confirmada'
      )::bigint,

    max(c.fecha_compra)
      filter (
        where c.estado =
          'confirmada'
      )

  into
    v_total_compras,
    v_compras_totales,
    v_ultima_compra

  from public.compras as c

  where c.comercio_id =
    v_comercio_id

    and c.proveedor_id =
      p_proveedor_id;

  select
    coalesce(
      sum(pc.importe)
        filter (
          where
            pc.estado =
              'registrado'

            and c.estado =
              'confirmada'
        ),
      0
    )::numeric(14,2),

    max(pc.fecha_pago)
      filter (
        where
          pc.estado =
            'registrado'

          and c.estado =
            'confirmada'
      )

  into
    v_total_pagado,
    v_ultimo_pago

  from public.pagos_compras
    as pc

  inner join public.compras
    as c
    on c.id =
      pc.compra_id

  where c.comercio_id =
    v_comercio_id

    and c.proveedor_id =
      p_proveedor_id;

  v_saldo_actual :=
    greatest(
      round(
        v_total_compras
        -
        v_total_pagado,
        2
      ),
      0
    );

  select
    count(*)::bigint

  into
    v_compras_pendientes

  from (
    select
      c.id,

      greatest(
        c.total
        -
        coalesce(
          sum(pc.importe)
            filter (
              where pc.estado =
                'registrado'
            ),
          0
        ),
        0
      )::numeric(14,2)
        as saldo_pendiente

    from public.compras as c

    left join public.pagos_compras
      as pc
      on pc.compra_id =
        c.id

    where c.comercio_id =
      v_comercio_id

      and c.proveedor_id =
        p_proveedor_id

      and c.estado =
        'confirmada'

    group by
      c.id,
      c.total
  ) as pendientes

  where pendientes.saldo_pendiente >
    0;

  v_ultima_actividad :=
    case
      when
        v_ultima_compra is null
        and v_ultimo_pago is null
      then null

      when v_ultima_compra is null
      then v_ultimo_pago

      when v_ultimo_pago is null
      then v_ultima_compra

      else greatest(
        v_ultima_compra,
        v_ultimo_pago
      )
    end;

  -- ===================================================
  -- SALDO ANTERIOR AL PERÍODO
  -- ===================================================

  if p_fecha_desde is not null then
    select
      (
        coalesce(
          sum(c.total)
            filter (
              where
                c.estado =
                  'confirmada'

                and c.fecha_compra <
                  p_fecha_desde
            ),
          0
        )
        -
        coalesce(
          (
            select
              sum(pc.importe)

            from public.pagos_compras
              as pc

            inner join public.compras
              as compra_pago
              on compra_pago.id =
                pc.compra_id

            where compra_pago.comercio_id =
              v_comercio_id

              and compra_pago.proveedor_id =
                p_proveedor_id

              and compra_pago.estado =
                'confirmada'

              and pc.estado =
                'registrado'

              and pc.fecha_pago <
                p_fecha_desde
          ),
          0
        )
      )::numeric(14,2)

    into
      v_saldo_anterior

    from public.compras as c

    where c.comercio_id =
      v_comercio_id

      and c.proveedor_id =
        p_proveedor_id;
  else
    v_saldo_anterior := 0;
  end if;

  -- ===================================================
  -- MOVIMIENTOS DEL PERÍODO Y SALDO ACUMULADO
  -- ===================================================

  with movimientos_base as (
    select
      c.id,

      'compra'::text
        as tipo,

      c.fecha_compra
        as fecha,

      c.numero::bigint
        as numero,

      format(
        'COM-%s',
        lpad(
          c.numero::text,
          6,
          '0'
        )
      )
        as comprobante,

      'Compra al proveedor'::text
        as descripcion,

      case
        when c.estado =
          'confirmada'
        then c.total
        else 0
      end::numeric(14,2)
        as debe,

      0::numeric(14,2)
        as haber,

      c.total::numeric(14,2)
        as importe,

      coalesce(
        nullif(
          trim(
            to_jsonb(c)
              ->> 'numero_comprobante'
          ),
          ''
        ),

        nullif(
          trim(
            to_jsonb(c)
              ->> 'comprobante_proveedor'
          ),
          ''
        ),

        nullif(
          trim(
            to_jsonb(c)
              ->> 'referencia'
          ),
          ''
        )
      )
        as referencia,

      null::text
        as medio_pago,

      nullif(
        trim(
          coalesce(
            to_jsonb(c)
              ->> 'observaciones',
            ''
          )
        ),
        ''
      )
        as observaciones,

      c.estado,
      c.created_at,

      1::integer
        as orden_tipo

    from public.compras as c

    where c.comercio_id =
      v_comercio_id

      and c.proveedor_id =
        p_proveedor_id

      and (
        p_fecha_desde is null
        or c.fecha_compra >=
          p_fecha_desde
      )

      and (
        p_fecha_hasta is null
        or c.fecha_compra <=
          p_fecha_hasta
      )

    union all

    select
      pc.id,

      'pago'::text
        as tipo,

      pc.fecha_pago
        as fecha,

      pc.numero::bigint
        as numero,

      format(
        'PAG-%s',
        lpad(
          pc.numero::text,
          6,
          '0'
        )
      )
        as comprobante,

      'Pago al proveedor'::text
        as descripcion,

      0::numeric(14,2)
        as debe,

      case
        when
          pc.estado =
            'registrado'

          and c.estado =
            'confirmada'
        then pc.importe
        else 0
      end::numeric(14,2)
        as haber,

      pc.importe::numeric(14,2)
        as importe,

      nullif(
        trim(
          coalesce(
            to_jsonb(pc)
              ->> 'referencia',
            ''
          )
        ),
        ''
      )
        as referencia,

      nullif(
        trim(
          coalesce(
            to_jsonb(pc)
              ->> 'medio_pago',
            ''
          )
        ),
        ''
      )
        as medio_pago,

      nullif(
        trim(
          coalesce(
            to_jsonb(pc)
              ->> 'observaciones',
            ''
          )
        ),
        ''
      )
        as observaciones,

      pc.estado,
      pc.created_at,

      2::integer
        as orden_tipo

    from public.pagos_compras
      as pc

    inner join public.compras
      as c
      on c.id =
        pc.compra_id

    where c.comercio_id =
      v_comercio_id

      and c.proveedor_id =
        p_proveedor_id

      and (
        p_fecha_desde is null
        or pc.fecha_pago >=
          p_fecha_desde
      )

      and (
        p_fecha_hasta is null
        or pc.fecha_pago <=
          p_fecha_hasta
      )
  ),

  movimientos_con_saldo as (
    select
      mb.*,

      (
        v_saldo_anterior
        +
        sum(
          mb.debe
          -
          mb.haber
        ) over (
          order by
            mb.fecha asc,
            mb.created_at asc,
            mb.orden_tipo asc,
            mb.numero asc
        )
      )::numeric(14,2)
        as saldo

    from movimientos_base as mb
  )

  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id',
            mcs.id,

          'tipo',
            mcs.tipo,

          'fecha',
            mcs.fecha,

          'numero',
            mcs.numero,

          'comprobante',
            mcs.comprobante,

          'descripcion',
            mcs.descripcion,

          'debe',
            mcs.debe,

          'haber',
            mcs.haber,

          'importe',
            mcs.importe,

          'referencia',
            mcs.referencia,

          'medio_pago',
            mcs.medio_pago,

          'observaciones',
            mcs.observaciones,

          'estado',
            mcs.estado,

          'created_at',
            mcs.created_at,

          'saldo',
            mcs.saldo
        )

        order by
          mcs.fecha asc,
          mcs.created_at asc,
          mcs.orden_tipo asc,
          mcs.numero asc
      ),
      '[]'::jsonb
    )

  into
    v_movimientos

  from movimientos_con_saldo
    as mcs;

  -- ===================================================
  -- RESUMEN DEL PERÍODO
  -- ===================================================

  select
    coalesce(
      sum(c.total)
        filter (
          where c.estado =
            'confirmada'
        ),
      0
    )::numeric(14,2)

  into
    v_cargos_periodo

  from public.compras as c

  where c.comercio_id =
    v_comercio_id

    and c.proveedor_id =
      p_proveedor_id

    and (
      p_fecha_desde is null
      or c.fecha_compra >=
        p_fecha_desde
    )

    and (
      p_fecha_hasta is null
      or c.fecha_compra <=
        p_fecha_hasta
    );

  select
    coalesce(
      sum(pc.importe)
        filter (
          where
            pc.estado =
              'registrado'

            and c.estado =
              'confirmada'
        ),
      0
    )::numeric(14,2)

  into
    v_pagos_periodo

  from public.pagos_compras
    as pc

  inner join public.compras
    as c
    on c.id =
      pc.compra_id

  where c.comercio_id =
    v_comercio_id

    and c.proveedor_id =
      p_proveedor_id

    and (
      p_fecha_desde is null
      or pc.fecha_pago >=
        p_fecha_desde
    )

    and (
      p_fecha_hasta is null
      or pc.fecha_pago <=
        p_fecha_hasta
    );

  v_saldo_final :=
    round(
      v_saldo_anterior
      +
      v_cargos_periodo
      -
      v_pagos_periodo,
      2
    );

  -- ===================================================
  -- RESPUESTA
  -- ===================================================

  return jsonb_build_object(
    'proveedor',
      jsonb_build_object(
        'id',
          p_proveedor_id,

        'comercio_id',
          v_comercio_id,

        'nombre',
          v_nombre_proveedor,

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
        'total_compras',
          v_total_compras,

        'total_pagado',
          v_total_pagado,

        'saldo_actual',
          v_saldo_actual,

        'compras_totales',
          v_compras_totales,

        'compras_pendientes',
          v_compras_pendientes,

        'ultima_compra',
          v_ultima_compra,

        'ultimo_pago',
          v_ultimo_pago,

        'ultima_actividad',
          v_ultima_actividad
      ),

    'resumen_periodo',
      jsonb_build_object(
        'saldo_anterior',
          v_saldo_anterior,

        'cargos',
          v_cargos_periodo,

        'pagos',
          v_pagos_periodo,

        'saldo_final',
          v_saldo_final
      ),

    'movimientos',
      v_movimientos
  );
end;
$$;

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on function
public.obtener_cuentas_corrientes_proveedores(
  uuid
)
from public;

grant execute
on function
public.obtener_cuentas_corrientes_proveedores(
  uuid
)
to authenticated;

revoke all
on function
public.obtener_cuenta_corriente_proveedor(
  uuid,
  date,
  date
)
from public;

grant execute
on function
public.obtener_cuenta_corriente_proveedor(
  uuid,
  date,
  date
)
to authenticated;

-- =====================================================
-- ACTUALIZAR CACHÉ DE POSTGREST
-- =====================================================

notify pgrst, 'reload schema';