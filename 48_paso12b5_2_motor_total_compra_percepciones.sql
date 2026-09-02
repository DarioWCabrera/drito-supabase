-- ============================================================
-- DRITO 12B.5.2
-- MOTOR DE TOTAL DE COMPRA + PERCEPCIONES SUFRIDAS
--
-- Archivo:
--   48_paso12b5_2_motor_total_compra_percepciones.sql
--
-- Regla económica:
--
--   TOTAL COMERCIAL DE LA COMPRA
--   + PERCEPCIONES SUFRIDAS VIGENTES
--   = TOTAL FINAL ADEUDADO AL PROVEEDOR
--
-- Importante:
--   - La percepción sufrida NO es un pago.
--   - NO cancela deuda.
--   - NO genera movimiento de Caja por sí sola.
--   - NO se incorpora a compras.impuestos.
--   - compras.total pasa a representar el total final.
--   - compras.total_pagado continúa representando deuda
--     cancelada por dinero + retenciones practicadas.
-- ============================================================

begin;


-- ============================================================
-- 0. DEPENDENCIAS
-- ============================================================

do $$
begin
  if to_regclass(
    'public.compras'
  ) is null then
    raise exception
      'Falta public.compras';
  end if;

  if to_regclass(
    'public.percepciones_sufridas'
  ) is null then
    raise exception
      'Falta public.percepciones_sufridas';
  end if;

  if to_regprocedure(
    'public.__drito_calcular_cancelacion_compra(uuid)'
  ) is null then
    raise exception
      'Falta public.__drito_calcular_cancelacion_compra(uuid)';
  end if;

  if to_regprocedure(
    'public.__drito_sincronizar_cancelacion_compra(uuid)'
  ) is null then
    raise exception
      'Falta public.__drito_sincronizar_cancelacion_compra(uuid)';
  end if;
end;
$$;


-- ============================================================
-- 1. CALCULAR TOTAL COMERCIAL + PERCEPCIONES SUFRIDAS
-- ============================================================

create or replace function
public.__drito_calcular_total_compra_con_percepciones(
  p_compra_id uuid
)
returns table (
  compra_id uuid,
  total_comercial numeric,
  percepciones_sufridas numeric,
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

  if p_compra_id is null then
    raise exception
      'La compra es obligatoria';
  end if;


  -- El total comercial se reconstruye desde el encabezado
  -- para no depender de compras.total, ya que compras.total
  -- pasa a contener el total final con percepciones.
  select
    round(
      greatest(
        (
          c.subtotal
          - c.descuento_items
          + c.impuestos
          - c.descuento_general_importe
        ),
        0
      ),
      2
    )::numeric(18,2)
  into v_total_comercial
  from public.compras as c
  where c.id = p_compra_id;


  if not found then
    raise exception
      'Compra no encontrada';
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
  from public.percepciones_sufridas as p
  where p.compra_id = p_compra_id
    and p.estado = 'registrada';


  v_total_final :=
    round(
      v_total_comercial
      + v_percepciones,
      2
    );


  return query
  select
    p_compra_id,
    v_total_comercial,
    v_percepciones,
    v_total_final;

end;
$$;


-- ============================================================
-- 2. SINCRONIZAR TOTAL DE LA COMPRA
-- ============================================================

create or replace function
public.__drito_sincronizar_total_compra_percepciones(
  p_compra_id uuid
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

  if p_compra_id is null then
    return;
  end if;


  if not exists (
    select 1
    from public.compras as c
    where c.id = p_compra_id
  ) then
    return;
  end if;


  select *
  into v_total
  from public.__drito_calcular_total_compra_con_percepciones(
    p_compra_id
  );


  -- El motor existente devuelve cuánto ya fue cancelado por:
  -- dinero real + retenciones practicadas.
  -- Una percepción sufrida NO forma parte de esa cancelación.
  select *
  into v_cancelacion
  from public.__drito_calcular_cancelacion_compra(
    p_compra_id
  );


  -- ==========================================================
  -- PROTECCIÓN CONTRA SOBRE-CANCELACIÓN
  --
  -- Si una percepción sufrida se reduce o se anula después de
  -- existir pagos/retenciones practicadas, el nuevo total final
  -- no puede quedar por debajo de lo ya cancelado.
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
      'No se puede reducir el total de la compra a %. Ya existen % cancelados. Primero debe regularizarse el pago o utilizarse el circuito fiscal/comercial correspondiente.',
      v_total.total_final,
      v_cancelacion.total_cancelado;
  end if;


  update public.compras as c
  set total =
    v_total.total_final
  where c.id =
    p_compra_id;


  -- Saldo y estado de pago continúan perteneciendo al motor
  -- central existente de cancelación de compras.
  perform
    public.__drito_sincronizar_cancelacion_compra(
      p_compra_id
    );

end;
$$;


-- ============================================================
-- 3. TRIGGER DE SINCRONIZACIÓN
-- ============================================================

create or replace function
public.__drito_percepcion_sufrida_sincronizar_compra()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_compra_nueva uuid;
  v_compra_anterior uuid;
begin

  if tg_op in (
    'INSERT',
    'UPDATE'
  ) then
    v_compra_nueva :=
      new.compra_id;
  end if;


  if tg_op in (
    'UPDATE',
    'DELETE'
  ) then
    v_compra_anterior :=
      old.compra_id;
  end if;


  if
    v_compra_anterior is not null
    and (
      v_compra_nueva is null
      or v_compra_anterior
        is distinct from
        v_compra_nueva
    )
  then
    perform
      public.__drito_sincronizar_total_compra_percepciones(
        v_compra_anterior
      );
  end if;


  if v_compra_nueva is not null then
    perform
      public.__drito_sincronizar_total_compra_percepciones(
        v_compra_nueva
      );
  end if;


  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;

end;
$$;


drop trigger if exists
percepciones_sufridas_sincronizar_compra
on public.percepciones_sufridas;

create trigger
percepciones_sufridas_sincronizar_compra
after insert or update or delete
on public.percepciones_sufridas
for each row
execute function
public.__drito_percepcion_sufrida_sincronizar_compra();


-- ============================================================
-- 4. SEGURIDAD DE FUNCIONES INTERNAS
-- ============================================================

revoke all
on function
public.__drito_calcular_total_compra_con_percepciones(uuid)
from public, anon, authenticated;

revoke all
on function
public.__drito_sincronizar_total_compra_percepciones(uuid)
from public, anon, authenticated;

revoke all
on function
public.__drito_percepcion_sufrida_sincronizar_compra()
from public, anon, authenticated;


-- ============================================================
-- 5. COMENTARIOS
-- ============================================================

comment on function
public.__drito_calcular_total_compra_con_percepciones(uuid)
is
'Calcula total comercial + percepciones sufridas registradas para una compra.';

comment on function
public.__drito_sincronizar_total_compra_percepciones(uuid)
is
'Sincroniza compras.total con las percepciones sufridas y luego recalcula cancelación, saldo y estado de pago. Bloquea reducciones por debajo de lo ya cancelado.';

comment on function
public.__drito_percepcion_sufrida_sincronizar_compra()
is
'Trigger interno que recalcula el total de una compra cuando una percepción sufrida se inserta, modifica, anula o elimina.';


commit;
