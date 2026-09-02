-- ============================================================
-- DRITO 12B.4.4
-- LISTADO SEGURO DE CONFIGURACIONES DE PERCEPCIÓN PARA VENTAS
--
-- Archivo:
--   46_paso12b4_4_listado_configuraciones_percepcion_venta.sql
--
-- Objetivo:
--   - Permitir que usuarios con permiso ventas.crear consulten
--     únicamente las configuraciones ACTIVAS y VIGENTES de
--     percepción aplicables a una venta.
--   - Evitar exponer acceso directo a
--     public.configuraciones_agentes_fiscales.
--   - No exigir facturacion.configurar para una operación
--     comercial normal.
--
-- Regla:
--   - Drito no infiere si un comercio es agente.
--   - No se hardcodean alícuotas ni regímenes.
--   - Solo se listan configuraciones explícitamente creadas
--     para el comercio y vigentes en la fecha consultada.
-- ============================================================

begin;

create or replace function public.listar_configuraciones_percepcion_venta(
  p_comercio_id uuid,
  p_fecha date default current_date
)
returns table (
  id uuid,
  organismo text,
  impuesto text,
  jurisdiccion text,
  regimen_codigo text,
  regimen_descripcion text,
  modo_alicuota text,
  alicuota_fija numeric,
  numero_inscripcion_agente text,
  sistema_presentacion text,
  vigencia_desde date,
  vigencia_hasta date
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  perform public.exigir_permiso_comercio(
    p_comercio_id,
    'ventas.crear'
  );

  return query
  select
    c.id,
    c.organismo,
    c.impuesto,
    c.jurisdiccion,
    c.regimen_codigo,
    c.regimen_descripcion,
    c.modo_alicuota,
    c.alicuota_fija,
    c.numero_inscripcion_agente,
    c.sistema_presentacion,
    c.vigencia_desde,
    c.vigencia_hasta
  from public.configuraciones_agentes_fiscales c
  where c.comercio_id = p_comercio_id
    and c.tipo_agente = 'percepcion'
    and c.activo = true
    and c.vigencia_desde <= coalesce(p_fecha, current_date)
    and (
      c.vigencia_hasta is null
      or c.vigencia_hasta >= coalesce(p_fecha, current_date)
    )
  order by
    c.organismo,
    c.impuesto,
    c.jurisdiccion nulls first,
    c.regimen_codigo nulls first;
end;
$$;

revoke all
on function public.listar_configuraciones_percepcion_venta(uuid, date)
from public;

revoke all
on function public.listar_configuraciones_percepcion_venta(uuid, date)
from anon;

grant execute
on function public.listar_configuraciones_percepcion_venta(uuid, date)
to authenticated;

commit;
