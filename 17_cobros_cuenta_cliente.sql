-- =====================================================
-- DRITO - COBRO GENERAL DE CUENTA CORRIENTE
--
-- Distribuye un cobro entre las ventas pendientes
-- del cliente, comenzando por las más antiguas.
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

  v_importe numeric(14,2);
  v_saldo_total numeric(14,2);
  v_saldo_final numeric(14,2);

  v_restante numeric(14,2);
  v_importe_aplicado numeric(14,2);

  v_medio_pago text;
  v_referencia text;
  v_observaciones text;

  v_ventas_afectadas integer := 0;

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

  if p_fecha_pago > current_date then
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
  -- SALDO TOTAL DEL CLIENTE
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

  if v_importe > v_saldo_total then
    raise exception
      'El importe supera el saldo pendiente del cliente. Saldo actual: %',
      v_saldo_total;
  end if;

  -- ===================================================
  -- DISTRIBUIR COBRO
  --
  -- Se aplican primero las ventas más antiguas.
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
    -- UTILIZAR EL SISTEMA EXISTENTE DE PAGOS
    --
    -- Esto mantiene:
    --   - contador PAG
    --   - total_pagado de la venta
    --   - estado de pago
    --   - movimiento automático de Caja
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
      v_referencia,
      coalesce(
        v_observaciones,
        'Cobro aplicado desde la cuenta corriente del cliente'
      )
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

  -- ===================================================
  -- CONTROL FINAL
  -- ===================================================

  if v_restante > 0 then
    raise exception
      'No fue posible aplicar la totalidad del cobro';
  end if;

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
-- PERMISOS
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

notify pgrst, 'reload schema';