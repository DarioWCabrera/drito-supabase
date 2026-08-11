-- =====================================================
-- DRITO - CORRECCIÓN ANULACIÓN DE GASTOS GENERALES
-- Archivo: 21b_fix_anulacion_gasto_estado_ambiguo.sql
--
-- Corrige PostgreSQL 42702:
-- column reference "estado" is ambiguous
--
-- La función devuelve una columna llamada "estado" y, al mismo
-- tiempo, movimientos_caja también posee una columna "estado".
-- Se califica la referencia del WHERE con el alias de la tabla.
-- =====================================================

create or replace function
public.anular_gasto_general(
  p_gasto_id uuid,
  p_motivo text
)
returns table (
  gasto_id uuid,
  numero bigint,
  comprobante text,
  importe_anulado numeric,
  estado text,
  movimiento_caja_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gasto public.gastos_generales;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if nullif(trim(coalesce(p_motivo, '')), '') is null
    or char_length(trim(p_motivo)) < 3 then
    raise exception
      'El motivo de anulación debe tener al menos 3 caracteres';
  end if;

  select gg.*
  into v_gasto
  from public.gastos_generales as gg
  where gg.id = p_gasto_id
  for update;

  if not found then
    raise exception 'Gasto no encontrado';
  end if;

  if not public.pertenece_a_comercio(
    v_gasto.comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio del gasto';
  end if;

  if v_gasto.estado = 'anulado' then
    raise exception 'El gasto ya se encuentra anulado';
  end if;

  update public.gastos_generales as gg
  set
    estado = 'anulado',
    motivo_anulacion = trim(p_motivo),
    anulado_por = auth.uid(),
    anulado_at = now()
  where gg.id = p_gasto_id;

  update public.movimientos_caja as mc
  set
    estado = 'anulado',
    motivo_anulacion = trim(p_motivo),
    anulado_por = auth.uid(),
    anulado_at = now(),
    updated_at = now()
  where mc.gasto_general_id = p_gasto_id
    and mc.estado <> 'anulado';

  return query
  select
    v_gasto.id,
    v_gasto.numero,
    format(
      'GTO-%s',
      lpad(v_gasto.numero::text, 6, '0')
    ),
    v_gasto.importe,
    'anulado'::text,
    v_gasto.movimiento_caja_id;
end;
$$;

grant execute on function
public.anular_gasto_general(uuid, text)
to authenticated;

-- Verificación opcional: muestra la definición instalada.
select pg_get_functiondef(
  'public.anular_gasto_general(uuid,text)'::regprocedure
);