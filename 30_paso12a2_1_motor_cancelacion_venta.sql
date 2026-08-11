-- =============================================================
-- DRITO - PASO 12A.2.1
-- MOTOR CENTRAL DE CANCELACION DE UNA VENTA
-- =============================================================
-- Este paso NO cambia todavía registrar_pago_venta.
-- Solo crea una función interna que calcula:
--
--   dinero recibido
-- + retenciones sufridas aplicadas a la venta
-- = total cancelado
--
-- Caja seguirá usando únicamente pagos_ventas.importe.
-- =============================================================

begin;

create or replace function
public.__drito_calcular_cancelacion_venta(
  p_venta_id uuid
)
returns table (
  venta_id uuid,
  total_venta numeric,
  dinero_recibido numeric,
  retenciones_sufridas numeric,
  total_cancelado numeric,
  saldo_pendiente numeric,
  estado_pago text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total_venta numeric(18,2);
  v_dinero numeric(18,2);
  v_retenciones numeric(18,2);
  v_cancelado numeric(18,2);
  v_saldo numeric(18,2);
  v_estado text;
begin
  if p_venta_id is null then
    raise exception 'La venta es obligatoria';
  end if;

  select round(v.total, 2)
  into v_total_venta
  from public.ventas as v
  where v.id = p_venta_id;

  if not found then
    raise exception 'Venta no encontrada';
  end if;

  -- Dinero efectivamente recibido.
  -- Este importe es el único que debe impactar Caja.
  select
    coalesce(
      sum(round(p.importe, 2)),
      0
    )::numeric(18,2)
  into v_dinero
  from public.pagos_ventas as p
  where p.venta_id = p_venta_id
    and p.estado = 'registrado';

  -- Retenciones sufridas aplicadas a esta venta.
  --
  -- Admitimos dos formas de relación:
  --   1) retencion.venta_id = venta
  --   2) retencion.pago_venta_id apunta a un PAG de la venta
  --
  -- DISTINCT evita duplicar una retención que tenga ambas
  -- referencias informadas.
  with retenciones_venta as (
    select distinct r.id, r.importe
    from public.retenciones_sufridas as r
    where r.estado = 'registrada'
      and (
        r.venta_id = p_venta_id
        or exists (
          select 1
          from public.pagos_ventas as pv
          where pv.id = r.pago_venta_id
            and pv.venta_id = p_venta_id
        )
      )
  )
  select
    coalesce(
      sum(round(rv.importe, 2)),
      0
    )::numeric(18,2)
  into v_retenciones
  from retenciones_venta as rv;

  v_cancelado :=
    round(v_dinero + v_retenciones, 2);

  v_saldo :=
    greatest(
      round(v_total_venta - v_cancelado, 2),
      0
    );

  if v_saldo = 0 then
    v_estado := 'pagada';
  elsif v_cancelado > 0 then
    v_estado := 'parcial';
  else
    v_estado := 'pendiente';
  end if;

  return query
  select
    p_venta_id,
    v_total_venta,
    v_dinero,
    v_retenciones,
    v_cancelado,
    v_saldo,
    v_estado;
end;
$$;

-- Función exclusivamente interna.
revoke all on function
public.__drito_calcular_cancelacion_venta(uuid)
from public, anon, authenticated;

comment on function
public.__drito_calcular_cancelacion_venta(uuid) is
  'Motor interno de cancelación de ventas: pagos reales + retenciones sufridas. No genera movimientos de Caja.';

commit;

-- =============================================================
-- VERIFICACION
-- =============================================================
-- Como todavía no registramos retenciones reales, para las ventas
-- existentes debería cumplirse:
--
-- dinero_recibido = total_cancelado
-- retenciones_sufridas = 0
--
select
  v.numero,
  v.total as total_guardado,
  v.total_pagado as total_pagado_guardado,
  c.dinero_recibido,
  c.retenciones_sufridas,
  c.total_cancelado,
  c.saldo_pendiente,
  c.estado_pago
from public.ventas as v
cross join lateral
  public.__drito_calcular_cancelacion_venta(v.id) as c
where v.estado = 'confirmada'
order by v.numero desc
limit 10;