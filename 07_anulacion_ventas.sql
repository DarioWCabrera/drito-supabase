-- =====================================================
-- DRITO - ANULACIÓN DE VENTAS
-- REPOSICIÓN AUTOMÁTICA DE STOCK
-- =====================================================

-- =====================================================
-- DATOS DE AUDITORÍA DE LA ANULACIÓN
-- =====================================================

alter table public.ventas
add column if not exists anulada_at timestamptz;

alter table public.ventas
add column if not exists anulada_por uuid
references auth.users(id)
on delete set null;

alter table public.ventas
add column if not exists motivo_anulacion text;

-- =====================================================
-- ÍNDICES
-- =====================================================

create index if not exists ventas_anulada_at_idx
on public.ventas (
  comercio_id,
  anulada_at desc
)
where estado = 'anulada';

-- =====================================================
-- ANULAR VENTA Y REPONER STOCK
-- =====================================================

create or replace function public.anular_venta(
  p_venta_id uuid,
  p_motivo text
)
returns table (
  venta_id uuid,
  numero_venta bigint,
  total_venta numeric,
  movimientos_generados integer,
  cantidad_total_repuesta numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venta public.ventas%rowtype;
  v_producto public.productos%rowtype;

  v_reposicion record;

  v_motivo text;

  v_stock_anterior numeric(14,3);
  v_stock_posterior numeric(14,3);

  v_movimientos_generados integer := 0;

  v_cantidad_total_repuesta numeric(14,3) := 0;
begin
  -- ===================================================
  -- VALIDACIONES GENERALES
  -- ===================================================

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;

  if p_venta_id is null then
    raise exception
      'La venta es obligatoria';
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

  -- Bloqueamos la venta durante toda la operación.
  --
  -- Esto evita que se registre un pago al mismo tiempo
  -- que la venta está siendo anulada.

  select v.*
  into v_venta
  from public.ventas as v
  where v.id = p_venta_id
  for update;

  if not found then
    raise exception
      'Venta no encontrada';
  end if;

  if not public.pertenece_a_comercio(
    v_venta.comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio';
  end if;

  if v_venta.estado = 'anulada' then
    raise exception
      'La venta ya se encuentra anulada';
  end if;

  if v_venta.estado <> 'confirmada' then
    raise exception
      'La venta no se encuentra confirmada';
  end if;

  -- ===================================================
  -- VALIDAR PAGOS VIGENTES
  -- ===================================================

  if exists (
    select 1
    from public.pagos_ventas as pv
    where pv.venta_id = v_venta.id
      and pv.estado = 'registrado'
  ) then
    raise exception
      'La venta tiene pagos vigentes. Anulá primero los pagos registrados';
  end if;

  -- Validación adicional ante posibles diferencias.

  if round(
    coalesce(
      v_venta.total_pagado,
      0
    ),
    2
  ) > 0 then
    raise exception
      'La venta todavía registra un importe pagado';
  end if;

  -- ===================================================
  -- VALIDAR ÍTEMS QUE AFECTAN STOCK
  -- ===================================================

  /*
    Si un artículo afectó stock, debemos conservar
    su producto_id para saber a qué producto devolver
    las existencias.
  */

  if exists (
    select 1
    from public.items_venta as iv
    where iv.venta_id = v_venta.id
      and iv.afecta_stock = true
      and iv.producto_id is null
  ) then
    raise exception
      'No se puede reponer el stock porque uno de los productos ya no existe';
  end if;

  -- ===================================================
  -- BLOQUEAR PRODUCTOS
  -- ===================================================

  /*
    Agrupamos por producto por seguridad.

    Aunque una venta tenga dos líneas del mismo
    producto, la reposición se realizará una sola vez
    por la cantidad total vendida.
  */

  for v_reposicion in
    select
      iv.producto_id,
      sum(iv.cantidad)::numeric(14,3)
        as cantidad_reponer
    from public.items_venta as iv
    where iv.venta_id = v_venta.id
      and iv.afecta_stock = true
      and iv.producto_id is not null
    group by iv.producto_id
    order by iv.producto_id
  loop
    select p.*
    into v_producto
    from public.productos as p
    where p.id = v_reposicion.producto_id
    for update;

    if not found then
      raise exception
        'Uno de los productos de la venta ya no existe';
    end if;

    if (
      v_producto.comercio_id
      <> v_venta.comercio_id
    ) then
      raise exception
        'Uno de los productos pertenece a otro comercio';
    end if;

    if v_reposicion.cantidad_reponer <= 0 then
      raise exception
        'La cantidad a reponer para el producto "%" no es válida',
        v_producto.nombre;
    end if;
  end loop;

  -- ===================================================
  -- REPONER STOCK
  -- ===================================================

  for v_reposicion in
    select
      iv.producto_id,
      sum(iv.cantidad)::numeric(14,3)
        as cantidad_reponer
    from public.items_venta as iv
    where iv.venta_id = v_venta.id
      and iv.afecta_stock = true
      and iv.producto_id is not null
    group by iv.producto_id
    order by iv.producto_id
  loop
    select p.*
    into v_producto
    from public.productos as p
    where p.id = v_reposicion.producto_id;

    v_stock_anterior :=
      v_producto.stock_actual;

    v_stock_posterior :=
      v_stock_anterior
      + v_reposicion.cantidad_reponer;

    update public.productos as p
    set
      stock_actual = v_stock_posterior
    where p.id = v_producto.id;

    /*
      Usamos tipo "entrada" para mantener compatibilidad
      con los tipos actuales del módulo de stock.

      El motivo y referencia identifican claramente que
      corresponde a una anulación de venta.
    */

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
      v_venta.comercio_id,
      v_producto.id,
      'entrada',
      v_reposicion.cantidad_reponer,
      v_stock_anterior,
      v_stock_posterior,

      format(
        'Reposición por anulación de venta VTA-%s',
        lpad(
          v_venta.numero::text,
          6,
          '0'
        )
      ),

      'anulacion_venta',
      v_venta.id,
      auth.uid()
    );

    v_movimientos_generados :=
      v_movimientos_generados + 1;

    v_cantidad_total_repuesta :=
      v_cantidad_total_repuesta
      + v_reposicion.cantidad_reponer;
  end loop;

  -- ===================================================
  -- MARCAR VENTA COMO ANULADA
  -- ===================================================

  update public.ventas as v
  set
    estado = 'anulada',
    estado_pago = 'pendiente',
    total_pagado = 0,
    motivo_anulacion = v_motivo,
    anulada_por = auth.uid(),
    anulada_at = now()
  where v.id = v_venta.id;

  -- ===================================================
  -- DEVOLVER RESULTADO
  -- ===================================================

  return query
  select
    v_venta.id,
    v_venta.numero,
    v_venta.total,
    v_movimientos_generados,
    v_cantidad_total_repuesta;
end;
$$;

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on function public.anular_venta(
  uuid,
  text
)
from public;

grant execute
on function public.anular_venta(
  uuid,
  text
)
to authenticated;