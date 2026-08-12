-- =============================================================
-- DRITO - MÓDULO 12A.4
-- Anulación segura de retenciones sufridas
-- Archivo: 32_paso12a4_anulacion_retencion_segura.sql
--
-- Objetivo:
--   - anular una retención sin borrarla;
--   - conservar trazabilidad (usuario, fecha y motivo);
--   - recalcular automáticamente la cancelación de la venta;
--   - NO generar ni anular movimientos de Caja, porque una
--     retención sufrida nunca representa dinero recibido.
--
-- Permiso utilizado:
--   ventas.anular_pagos
--
-- Dependencias:
--   - public.retenciones_sufridas
--   - public.exigir_permiso_comercio(uuid,text)
--   - public.__drito_calcular_cancelacion_venta(uuid)
--   - trigger retenciones_sufridas_sincronizar_venta
-- =============================================================

begin;

-- -------------------------------------------------------------
-- 1. VALIDACIÓN DE DEPENDENCIAS
-- -------------------------------------------------------------
do $$
begin
  if to_regclass('public.retenciones_sufridas') is null then
    raise exception 'Falta public.retenciones_sufridas';
  end if;

  if to_regprocedure(
    'public.exigir_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta public.exigir_permiso_comercio(uuid,text)';
  end if;

  if to_regprocedure(
    'public.__drito_calcular_cancelacion_venta(uuid)'
  ) is null then
    raise exception
      'Falta public.__drito_calcular_cancelacion_venta(uuid)';
  end if;

  if not exists (
    select 1
    from pg_trigger tg
    join pg_class c
      on c.oid = tg.tgrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'retenciones_sufridas'
      and tg.tgname =
        'retenciones_sufridas_sincronizar_venta'
      and not tg.tgisinternal
  ) then
    raise exception
      'Falta trigger retenciones_sufridas_sincronizar_venta';
  end if;
end;
$$;

-- -------------------------------------------------------------
-- 2. RPC DE ANULACIÓN
-- -------------------------------------------------------------
create or replace function
public.anular_retencion_sufrida(
  p_retencion_id uuid,
  p_motivo text
)
returns table (
  retencion_id uuid,
  numero_certificado text,
  venta_id uuid,
  importe_retencion numeric,
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
  v_usuario_id uuid;
  v_retencion public.retenciones_sufridas%rowtype;
  v_venta_id uuid;
  v_motivo text;
  v_resumen record;
begin
  v_usuario_id := auth.uid();

  if v_usuario_id is null then
    raise exception 'Debés iniciar sesión para anular una retención';
  end if;

  if p_retencion_id is null then
    raise exception 'La retención es obligatoria';
  end if;

  v_motivo := nullif(trim(coalesce(p_motivo, '')), '');

  if v_motivo is null
     or char_length(v_motivo) < 3 then
    raise exception
      'Ingresá un motivo de anulación de al menos 3 caracteres';
  end if;

  if char_length(v_motivo) > 250 then
    raise exception
      'El motivo de anulación no puede superar los 250 caracteres';
  end if;

  select rs.*
  into v_retencion
  from public.retenciones_sufridas as rs
  where rs.id = p_retencion_id
  for update;

  if not found then
    raise exception 'Retención no encontrada';
  end if;

  perform public.exigir_permiso_comercio(
    v_retencion.comercio_id,
    'ventas.anular_pagos'
  );

  if v_retencion.estado = 'anulada' then
    raise exception 'La retención ya se encuentra anulada';
  end if;

  -- La retención puede venir asociada directamente a una venta
  -- o indirectamente mediante el pago de venta.
  v_venta_id := v_retencion.venta_id;

  if v_venta_id is null
     and v_retencion.pago_venta_id is not null then
    select pv.venta_id
    into v_venta_id
    from public.pagos_ventas as pv
    where pv.id = v_retencion.pago_venta_id;
  end if;

  if v_venta_id is null then
    raise exception
      'La retención no está vinculada a una venta';
  end if;

  -- No se borra la fila. Se conserva la evidencia fiscal completa.
  -- El trigger de 12A.2.2 recalcula la venta después del UPDATE.
  update public.retenciones_sufridas
  set
    estado = 'anulada',
    anulado_por = v_usuario_id,
    anulado_at = now(),
    motivo_anulacion = v_motivo
  where id = v_retencion.id;

  -- El trigger retenciones_sufridas_sincronizar_venta ya ejecutó
  -- la resincronización. Leemos el estado final para devolverlo
  -- al frontend y poder auditar la prueba.
  select *
  into v_resumen
  from public.__drito_calcular_cancelacion_venta(
    v_venta_id
  );

  return query
  select
    v_retencion.id,
    v_retencion.numero_certificado,
    v_venta_id,
    v_retencion.importe,
    v_resumen.dinero_recibido,
    v_resumen.retenciones_sufridas,
    v_resumen.total_cancelado,
    v_resumen.saldo_pendiente,
    v_resumen.estado_pago;
end;
$$;

-- -------------------------------------------------------------
-- 3. SEGURIDAD
-- -------------------------------------------------------------
revoke all on function
public.anular_retencion_sufrida(uuid, text)
from public, anon, authenticated;

grant execute on function
public.anular_retencion_sufrida(uuid, text)
to authenticated;

commit;

-- =============================================================
-- FIN 12A.4 - La verificación se ejecutará por separado.
-- =============================================================