-- ============================================================
-- DRITO
-- PASO 13A.2.1 - FIX NORMALIZADOR DE ESTADO DE PAGO EN COMPRAS
-- Archivo: 54_paso13a2_1_fix_estado_pago_al_crear_compra.sql
--
-- Problema detectado:
--   compras_normalizar_resumen_cancelacion es un trigger BEFORE UPDATE
--   de total_pagado / estado_pago.
--
--   Al crear una compra, la cabecera nace temporalmente con total = 0
--   y luego el motor actualiza en una misma sentencia:
--     - total
--     - total_pagado
--     - estado_pago
--
--   El normalizador llamaba a __drito_calcular_cancelacion_compra(),
--   que dentro de un BEFORE UPDATE todavía leía de la tabla el total
--   ANTERIOR (= 0). Por eso concluía saldo = 0 y marcaba la compra
--   como "pagada", aun sin pagos ni movimientos de Caja.
--
-- Solución:
--   - conservar el motor central para obtener cuánto fue realmente
--     cancelado (dinero + retenciones);
--   - calcular saldo y estado usando NEW.total, que es el total que
--     efectivamente quedará persistido al finalizar el UPDATE.
--
-- Alcance:
--   - no modifica datos existentes;
--   - no toca Caja;
--   - no toca pagos, retenciones ni percepciones;
--   - no cambia firmas públicas;
--   - no cambia el trigger existente;
--   - corrige cualquier UPDATE donde total y resumen de cancelación
--     cambien dentro de la misma sentencia.
-- ============================================================

begin;

-- ============================================================
-- 1. PRECONDICIONES
-- ============================================================

do $$
begin
  if to_regprocedure(
    'public.__drito_normalizar_resumen_cancelacion_compra()'
  ) is null then
    raise exception
      'No existe public.__drito_normalizar_resumen_cancelacion_compra()';
  end if;

  if to_regprocedure(
    'public.__drito_calcular_cancelacion_compra(uuid)'
  ) is null then
    raise exception
      'No existe public.__drito_calcular_cancelacion_compra(uuid)';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.compras'::regclass
      and tgname = 'compras_normalizar_resumen_cancelacion'
      and not tgisinternal
  ) then
    raise exception
      'No existe el trigger compras_normalizar_resumen_cancelacion';
  end if;
end;
$$;

-- ============================================================
-- 2. NORMALIZADOR CORREGIDO
-- ============================================================

create or replace function public.__drito_normalizar_resumen_cancelacion_compra()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_resumen record;

  v_total_nuevo numeric(18,2);
  v_total_cancelado numeric(18,2);
  v_saldo_nuevo numeric(18,2);
begin

  if new.estado <> 'confirmada' then
    return new;
  end if;

  -- El motor central sigue siendo la única fuente para calcular
  -- dinero + retenciones efectivamente aplicados a la compra.
  --
  -- IMPORTANTE:
  -- Como este trigger es BEFORE UPDATE, el motor todavía puede leer
  -- desde public.compras el OLD.total. Por eso NO reutilizamos aquí
  -- su saldo_pendiente ni su estado_pago.
  select *
  into v_resumen
  from public.__drito_calcular_cancelacion_compra(
    new.id
  );

  v_total_cancelado :=
    round(
      coalesce(
        v_resumen.total_cancelado,
        0
      ),
      2
    );

  -- NEW.total representa el total que quedará persistido después
  -- de este mismo UPDATE.
  v_total_nuevo :=
    round(
      coalesce(
        new.total,
        0
      ),
      2
    );

  v_saldo_nuevo :=
    greatest(
      round(
        v_total_nuevo
        - v_total_cancelado,
        2
      ),
      0
    );

  new.total_pagado :=
    v_total_cancelado;

  new.estado_pago :=
    case

      when v_saldo_nuevo <= 0
        then 'pagada'

      when v_total_cancelado > 0
        then 'parcial'

      else 'pendiente'

    end;

  return new;

end;
$function$;

comment on function public.__drito_normalizar_resumen_cancelacion_compra() is
  'Normaliza total_pagado y estado_pago usando cancelación real y NEW.total. Corrige el caso BEFORE UPDATE donde el total persistido anterior aún era 0 durante el alta de una compra.';

-- ============================================================
-- 3. SEGURIDAD DEL HELPER INTERNO
-- ============================================================

revoke all
on function public.__drito_normalizar_resumen_cancelacion_compra()
from public;

revoke all
on function public.__drito_normalizar_resumen_cancelacion_compra()
from anon;

revoke all
on function public.__drito_normalizar_resumen_cancelacion_compra()
from authenticated;

-- ============================================================
-- 4. ASSERTIONS ESTRUCTURALES
-- ============================================================

do $$
declare
  v_trigger_funcion text;
begin

  select p.proname
  into v_trigger_funcion
  from pg_trigger t
  join pg_proc p
    on p.oid = t.tgfoid
  where t.tgrelid = 'public.compras'::regclass
    and t.tgname = 'compras_normalizar_resumen_cancelacion'
    and not t.tgisinternal;

  if v_trigger_funcion
     <> '__drito_normalizar_resumen_cancelacion_compra' then
    raise exception
      'El trigger de normalización apunta a una función inesperada: %',
      coalesce(v_trigger_funcion, 'NULL');
  end if;

  if has_function_privilege(
    'authenticated',
    'public.__drito_normalizar_resumen_cancelacion_compra()',
    'EXECUTE'
  ) then
    raise exception
      'El normalizador interno no debe ser ejecutable directamente por authenticated';
  end if;
end;
$$;

commit;
