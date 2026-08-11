-- ============================================================
-- DRITO - MODULO 28 / PASO 10D-A
-- Numeración segura para máquina de estados de emisión
-- Fecha: 2026-08-09
--
-- Objetivo:
-- - permitir que un número rechazado/error pueda volver a intentarse
--   en una nueva operación lógica, porque ARCA no lo autorizó;
-- - mantener exclusividad absoluta mientras el número está reservado,
--   enviándose, incierto o ya autorizado;
-- - no emitir, no llamar ARCA y no modificar CAE.
-- ============================================================

begin;

-- El índice original incluía también estados rechazado/error. Eso podría
-- impedir reutilizar el próximo número oficial cuando ARCA rechazó una
-- solicitud y, por lo tanto, no consumió ese número.
drop index if exists public.comprobantes_fiscales_numeracion_unica_idx;

create unique index comprobantes_fiscales_numeracion_unica_idx
on public.comprobantes_fiscales (
  comercio_id,
  ambiente_arca,
  punto_venta_numero,
  tipo_comprobante_arca,
  numero_comprobante
)
where numero_comprobante is not null
  and estado in (
    'pendiente_autorizacion',
    'enviando',
    'incierto',
    'autorizado'
  );

comment on index public.comprobantes_fiscales_numeracion_unica_idx is
  'Reserva un número fiscal sólo mientras está pendiente/enviando/incierto o autorizado. Rechazado/error no consumen numeración autorizada.';

commit;

-- Verificación: debe devolver la definición del índice con los 4 estados.
select
  indexname,
  indexdef
from pg_indexes
where schemaname = 'public'
  and tablename = 'comprobantes_fiscales'
  and indexname = 'comprobantes_fiscales_numeracion_unica_idx';