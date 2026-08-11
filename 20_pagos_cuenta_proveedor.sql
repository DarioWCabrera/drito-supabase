-- =====================================================
-- DRITO - CORRECCIÓN DE CAJA PARA PAGOS AGRUPADOS
-- Archivo: 20c_fix_caja_pagos_agrupados_proveedores.sql
--
-- Evita que los PAG internos creados por un PPR generen
-- movimientos duplicados en Caja.
--
-- Regla final:
--   - Pago directo de una compra (PAG sin PPR): sí va a Caja.
--   - Pago agrupado de proveedor (PPR): solo el PPR va a Caja.
-- =====================================================

create or replace function
public.sincronizar_pago_con_caja_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cobro_en_proceso text;
begin
  if tg_table_name = 'pagos_ventas' then
    v_cobro_en_proceso :=
      nullif(
        current_setting(
          'drito.cobro_agrupado_id',
          true
        ),
        ''
      );

    -- El pago pertenece a un cobro agrupado de cliente.
    -- Caja recibe únicamente el comprobante COB principal.
    if (
      new.cobro_cliente_id is not null
      or v_cobro_en_proceso is not null
    ) then
      return new;
    end if;

    perform
      public.sincronizar_pago_caja_desde_json(
        'pago_venta',
        to_jsonb(new)
      );

  elsif tg_table_name = 'pagos_compras' then
    -- El PAG fue generado internamente por un pago agrupado PPR.
    -- No debe crear ni actualizar un movimiento individual en Caja,
    -- porque Caja ya recibe un único egreso por el PPR principal.
    if new.pago_proveedor_id is not null then
      return new;
    end if;

    -- Pago directo registrado desde una compra.
    perform
      public.sincronizar_pago_caja_desde_json(
        'pago_compra',
        to_jsonb(new)
      );

  else
    raise exception
      'La tabla "%" no está soportada por la integración de Caja',
      tg_table_name;
  end if;

  return new;
end;
$$;

-- =====================================================
-- VERIFICACIÓN
-- Devuelve la definición actualizada de la función.
-- =====================================================

select pg_get_functiondef(
  'public.sincronizar_pago_con_caja_trigger()'::regprocedure
);