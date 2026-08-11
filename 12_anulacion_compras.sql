-- =====================================================
-- DRITO - ANULACIÓN DE COMPRAS
-- REVERSIÓN AUTOMÁTICA DEL STOCK
-- =====================================================

-- Estas columnas ya fueron incluidas originalmente
-- en compras. Las agregamos de forma idempotente
-- para asegurar compatibilidad.

alter table public.compras
add column if not exists anulada_at timestamptz;

alter table public.compras
add column if not exists anulada_por uuid
references auth.users(id)
on delete set null;

alter table public.compras
add column if not exists motivo_anulacion text;

-- =====================================================
-- ANULAR COMPRA
-- =====================================================

create or replace function public.anular_compra(
  p_compra_id uuid,
  p_motivo text
)
returns table (
  compra_id uuid,
  numero_compra bigint,
  movimientos_generados integer,
  cantidad_total_revertida numeric,
  estado_compra text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comercio_id uuid;
  v_numero_compra bigint;

  v_estado_compra text;
  v_total_pagado numeric(14,2);

  v_motivo text;

  v_item record;
  v_producto public.productos%rowtype;

  v_stock_anterior numeric(14,3);
  v_stock_posterior numeric(14,3);

  v_movimientos_generados integer := 0;

  v_cantidad_total_revertida
    numeric(14,3) := 0;
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

  -- Bloqueamos la compra.
  -- registrar_pago_compra también bloquea la compra,
  -- evitando pagos y anulaciones simultáneas.

  select
    c.comercio_id,
    c.numero,
    c.estado,
    c.total_pagado
  into
    v_comercio_id,
    v_numero_compra,
    v_estado_compra,
    v_total_pagado
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

  if v_estado_compra = 'anulada' then
    raise exception
      'La compra ya se encuentra anulada';
  end if;

  if v_estado_compra <> 'confirmada' then
    raise exception
      'La compra no puede ser anulada en su estado actual';
  end if;

  -- ===================================================
  -- PAGOS ACTIVOS
  -- ===================================================

  if (
    coalesce(v_total_pagado, 0) > 0
    or exists (
      select 1
      from public.pagos_compras as pc
      where pc.compra_id = p_compra_id
        and pc.estado = 'registrado'
    )
  ) then
    raise exception
      'La compra tiene pagos vigentes. Anule primero todos los pagos registrados';
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

  -- ===================================================
  -- REVERSIÓN DE STOCK
  -- ===================================================

  -- Agrupamos por producto para que la función también
  -- sea segura ante datos históricos con líneas repetidas.

  for v_item in
    select
      ic.producto_id,

      sum(
        ic.cantidad
      )::numeric(14,3) as cantidad

    from public.items_compra as ic

    where ic.compra_id = p_compra_id
      and ic.afecta_stock = true

    group by ic.producto_id

    order by ic.producto_id
  loop
    -- Bloqueamos cada producto antes de cambiar stock.

    select p.*
    into v_producto
    from public.productos as p
    where p.id = v_item.producto_id
    for update;

    if not found then
      raise exception
        'Uno de los productos de la compra ya no existe';
    end if;

    if v_producto.comercio_id <> v_comercio_id then
      raise exception
        'Uno de los productos pertenece a otro comercio';
    end if;

    v_stock_anterior :=
      coalesce(
        v_producto.stock_actual,
        0
      );

    -- No permitimos generar stock negativo.
    -- Esto puede suceder si parte de la mercadería
    -- comprada ya fue vendida o retirada.

    if v_stock_anterior < v_item.cantidad then
      raise exception
        'No hay stock suficiente para anular la compra. Producto: "%". Stock actual: %. Cantidad a revertir: %',
        v_producto.nombre,
        v_stock_anterior,
        v_item.cantidad;
    end if;

    v_stock_posterior :=
      v_stock_anterior
      - v_item.cantidad;

    update public.productos as p
    set
      stock_actual =
        v_stock_posterior
    where p.id = v_producto.id;

    insert into public.movimientos_stock (
      comercio_id,
      producto_id,
      tipo,
      cantidad,
      stock_anterior,
      stock_posterior,
      motivo,
      referencia_tipo,
      referencia_id,
      creado_por
    )
    values (
      v_comercio_id,
      v_producto.id,
      'devolucion_proveedor',
      v_item.cantidad,
      v_stock_anterior,
      v_stock_posterior,

      format(
        'Reversión por anulación de compra COM-%s',
        lpad(
          v_numero_compra::text,
          6,
          '0'
        )
      ),

      'anulacion_compra',
      p_compra_id,
      auth.uid()
    );

    v_movimientos_generados :=
      v_movimientos_generados + 1;

    v_cantidad_total_revertida :=
      v_cantidad_total_revertida
      + v_item.cantidad;
  end loop;

  -- ===================================================
  -- ANULAR COMPRA
  -- ===================================================

  update public.compras as c
  set
    estado = 'anulada',

    total_pagado = 0,
    estado_pago = 'pendiente',

    anulada_at = now(),
    anulada_por = auth.uid(),
    motivo_anulacion = v_motivo

  where c.id = p_compra_id;

  -- ===================================================
  -- RESULTADO
  -- ===================================================

  return query
  select
    p_compra_id,
    v_numero_compra,
    v_movimientos_generados,
    v_cantidad_total_revertida,
    'anulada'::text;
end;
$$;

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on function public.anular_compra(
  uuid,
  text
)
from public;

grant execute
on function public.anular_compra(
  uuid,
  text
)
to authenticated;