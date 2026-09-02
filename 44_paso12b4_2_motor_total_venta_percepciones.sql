-- ============================================================
-- DRITO 12B.4.2
-- MOTOR DE TOTALIZACIÓN DE VENTAS CON PERCEPCIONES PRACTICADAS
-- Archivo: 44_paso12b4_2_motor_total_venta_percepciones.sql
--
-- Regla económica:
--
--   total comercial de la venta
--   + percepciones practicadas registradas
--   = total final a cobrar
--
-- La percepción aumenta la deuda del cliente.
-- No representa ingreso de Caja por sí misma.
--
-- Esta migración:
--   - NO genera percepciones automáticamente.
--   - NO crea movimientos de Caja.
--   - NO modifica pagos existentes.
--   - Sincroniza total / saldo / estado de pago cuando cambia
--     una percepción practicada.
--   - Bloquea una reducción del total si lo ya cancelado
--     supera el nuevo total.
-- ============================================================

begin;


-- ============================================================
-- 0. DEPENDENCIAS
-- ============================================================

do $$
begin

  if to_regclass(
    'public.ventas'
  ) is null then
    raise exception
      'Falta public.ventas';
  end if;


  if to_regclass(
    'public.percepciones_practicadas'
  ) is null then
    raise exception
      'Falta public.percepciones_practicadas. Ejecutá primero la migración 43.';
  end if;


  if to_regprocedure(
    'public.__drito_calcular_cancelacion_venta(uuid)'
  ) is null then
    raise exception
      'Falta public.__drito_calcular_cancelacion_venta(uuid)';
  end if;


  if to_regprocedure(
    'public.__drito_sincronizar_cancelacion_venta(uuid)'
  ) is null then
    raise exception
      'Falta public.__drito_sincronizar_cancelacion_venta(uuid)';
  end if;

end;
$$;


-- ============================================================
-- 1. CALCULAR TOTAL COMERCIAL + PERCEPCIONES
-- ============================================================

create or replace function
public.__drito_calcular_total_venta_con_percepciones(
  p_venta_id uuid
)

returns table (
  venta_id uuid,
  total_comercial numeric,
  percepciones_practicadas numeric,
  total_final numeric
)

language plpgsql
security definer
set search_path = public

as $$

declare

  v_total_comercial numeric(18,2);
  v_percepciones numeric(18,2);
  v_total_final numeric(18,2);

begin

  if p_venta_id is null then
    raise exception
      'La venta es obligatoria';
  end if;


  select
    round(
      greatest(
        (
          v.subtotal
          - v.descuento_items
          + v.impuestos
          - v.descuento_general_importe
        ),
        0
      ),
      2
    )::numeric(18,2)

  into v_total_comercial

  from public.ventas as v

  where v.id = p_venta_id;


  if not found then
    raise exception
      'Venta no encontrada';
  end if;


  select
    coalesce(
      sum(
        round(
          p.importe,
          2
        )
      ),
      0
    )::numeric(18,2)

  into v_percepciones

  from public.percepciones_practicadas as p

  where p.venta_id = p_venta_id
    and p.estado = 'registrada';


  v_total_final :=
    round(
      v_total_comercial
      + v_percepciones,
      2
    );


  return query

  select
    p_venta_id,
    v_total_comercial,
    v_percepciones,
    v_total_final;

end;
$$;


-- ============================================================
-- 2. SINCRONIZAR LA VENTA
-- ============================================================

create or replace function
public.__drito_sincronizar_total_venta_percepciones(
  p_venta_id uuid
)

returns void

language plpgsql
security definer
set search_path = public

as $$

declare

  v_total record;
  v_cancelacion record;

begin

  if p_venta_id is null then
    return;
  end if;


  if not exists (
    select 1
    from public.ventas as v
    where v.id = p_venta_id
  ) then
    return;
  end if;


  select *
  into v_total

  from public.__drito_calcular_total_venta_con_percepciones(
    p_venta_id
  );


  select *
  into v_cancelacion

  from public.__drito_calcular_cancelacion_venta(
    p_venta_id
  );


  -- ==========================================================
  -- PROTECCIÓN CONTRA SOBRE-CANCELACIÓN
  --
  -- Si una percepción se reduce o se anula después de existir
  -- dinero/retenciones sufridas aplicadas, el nuevo total no
  -- puede quedar por debajo de lo ya cancelado.
  -- ==========================================================

  if
    round(
      v_cancelacion.total_cancelado,
      2
    )
    >
    round(
      v_total.total_final,
      2
    )
  then

    raise exception
      'No se puede reducir el total de la venta a %. Ya existen % cancelados. Primero debe regularizarse la cobranza o utilizarse el circuito fiscal/comercial correspondiente.',
      v_total.total_final,
      v_cancelacion.total_cancelado;

  end if;


  update public.ventas as v

  set total =
    v_total.total_final

  where v.id =
    p_venta_id;


  -- El saldo y estado de pago continúan perteneciendo
  -- al motor central de cancelación de ventas.
  perform
    public.__drito_sincronizar_cancelacion_venta(
      p_venta_id
    );

end;
$$;


-- ============================================================
-- 3. TRIGGER DE SINCRONIZACIÓN
-- ============================================================

create or replace function
public.__drito_percepcion_sincronizar_venta()

returns trigger

language plpgsql
security definer
set search_path = public

as $$

declare

  v_venta_nueva uuid;
  v_venta_anterior uuid;

begin

  if tg_op in (
    'INSERT',
    'UPDATE'
  ) then

    v_venta_nueva :=
      new.venta_id;

  end if;


  if tg_op in (
    'UPDATE',
    'DELETE'
  ) then

    v_venta_anterior :=
      old.venta_id;

  end if;


  if
    v_venta_anterior is not null
    and (
      v_venta_nueva is null
      or v_venta_anterior
        is distinct from
        v_venta_nueva
    )
  then

    perform
      public.__drito_sincronizar_total_venta_percepciones(
        v_venta_anterior
      );

  end if;


  if v_venta_nueva is not null then

    perform
      public.__drito_sincronizar_total_venta_percepciones(
        v_venta_nueva
      );

  end if;


  if tg_op = 'DELETE' then
    return old;
  end if;


  return new;

end;
$$;


drop trigger if exists
percepciones_practicadas_sincronizar_venta

on public.percepciones_practicadas;


create trigger
percepciones_practicadas_sincronizar_venta

after insert or update or delete

on public.percepciones_practicadas

for each row

execute function
public.__drito_percepcion_sincronizar_venta();


-- ============================================================
-- 4. SEGURIDAD DE FUNCIONES INTERNAS
-- ============================================================

revoke all

on function
public.__drito_calcular_total_venta_con_percepciones(uuid)

from public, anon, authenticated;


revoke all

on function
public.__drito_sincronizar_total_venta_percepciones(uuid)

from public, anon, authenticated;


revoke all

on function
public.__drito_percepcion_sincronizar_venta()

from public, anon, authenticated;


-- ============================================================
-- 5. COMENTARIOS
-- ============================================================

comment on function
public.__drito_calcular_total_venta_con_percepciones(uuid)

is
'Calcula total comercial + percepciones practicadas registradas para una venta.';


comment on function
public.__drito_sincronizar_total_venta_percepciones(uuid)

is
'Sincroniza ventas.total con las percepciones practicadas y luego recalcula cancelación, saldo y estado de pago. Bloquea reducciones por debajo de lo ya cancelado.';


comment on function
public.__drito_percepcion_sincronizar_venta()

is
'Trigger interno que recalcula el total de una venta cuando una percepción practicada se inserta, modifica, anula o elimina.';


commit;
