-- =============================================================
-- DRITO - PASO 12B.2.2
-- MOTOR CENTRAL DE CANCELACIÓN DE COMPRAS
-- CON RETENCIONES PRACTICADAS
-- =============================================================
--
-- Regla económica:
--
--   deuda cancelada =
--       dinero efectivamente pagado
--       + retenciones practicadas vigentes
--
--   Caja =
--       solamente dinero efectivamente pagado
--
-- Este paso:
--   - NO modifica todavía el frontend.
--   - NO reemplaza las RPC públicas de pago.
--   - NO genera retenciones reales.
--   - NO genera movimientos nuevos de Caja.
--
-- Prepara un único motor de verdad para:
--
--   a) pago individual de compra
--   b) pago agrupado a proveedor
--   c) retención sin dinero efectivo
--   d) retención agrupada aplicada a varias compras
--
-- =============================================================

begin;


-- =============================================================
-- 0. PRECONDICIONES
-- =============================================================

do $$
begin

  if to_regclass(
    'public.compras'
  ) is null then
    raise exception
      'Falta public.compras';
  end if;


  if to_regclass(
    'public.pagos_compras'
  ) is null then
    raise exception
      'Falta public.pagos_compras';
  end if;


  if to_regclass(
    'public.pagos_proveedores'
  ) is null then
    raise exception
      'Falta public.pagos_proveedores';
  end if;


  if to_regclass(
    'public.retenciones_practicadas'
  ) is null then
    raise exception
      'Falta public.retenciones_practicadas. Ejecutá primero el paso 12B.2.1';
  end if;


  if to_regprocedure(
    'public.actualizar_resumen_pago_compra(uuid)'
  ) is null then
    raise exception
      'Falta public.actualizar_resumen_pago_compra(uuid)';
  end if;


  if to_regprocedure(
    'public.tiene_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta public.tiene_permiso_comercio(uuid,text)';
  end if;

end;
$$;


-- =============================================================
-- 1. AJUSTE DE ORIGEN DE RETENCIÓN INDIVIDUAL
-- =============================================================
--
-- El modelo anterior exigía:
--
--   compra_id + pago_compra_id
--
-- para toda retención individual.
--
-- Eso impediría una operación compuesta solamente por retención
-- y sin salida de dinero.
--
-- Desde este paso:
--
-- INDIVIDUAL:
--   compra_id obligatorio
--   pago_compra_id opcional
--   pago_proveedor_id NULL
--
-- AGRUPADA:
--   compra_id NULL
--   pago_compra_id NULL
--   pago_proveedor_id obligatorio
--
-- =============================================================

alter table public.retenciones_practicadas
  drop constraint if exists
  retenciones_practicadas_check1;


alter table public.retenciones_practicadas
  drop constraint if exists
  retenciones_practicadas_origen_pago_check;


alter table public.retenciones_practicadas
  add constraint
  retenciones_practicadas_origen_pago_check
  check (

    (
      compra_id is not null
      and pago_proveedor_id is null
    )

    or

    (
      compra_id is null
      and pago_compra_id is null
      and pago_proveedor_id is not null
    )

  );


-- =============================================================
-- 2. VALIDACIÓN EXTRA DE COMPRA DIRECTA
-- =============================================================
--
-- Si una retención individual no tiene pago_compra_id porque
-- todo fue retenido, igualmente debemos validar la compra.
-- =============================================================

create or replace function
public.__drito_validar_retencion_practicada_compra_directa()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare

  v_comercio_compra uuid;
  v_proveedor_compra uuid;
  v_estado_compra text;

begin

  if new.compra_id is null then
    return new;
  end if;


  select
    c.comercio_id,
    c.proveedor_id,
    c.estado
  into
    v_comercio_compra,
    v_proveedor_compra,
    v_estado_compra
  from public.compras as c
  where c.id = new.compra_id;


  if not found then
    raise exception
      'Compra inexistente';
  end if;


  if v_comercio_compra <> new.comercio_id then
    raise exception
      'La retención y la compra pertenecen a comercios diferentes';
  end if;


  if v_proveedor_compra <> new.proveedor_id then
    raise exception
      'La retención y la compra pertenecen a proveedores diferentes';
  end if;


  if v_estado_compra <> 'confirmada' then
    raise exception
      'La compra no admite nuevas retenciones';
  end if;


  return new;

end;
$$;


revoke all
on function
public.__drito_validar_retencion_practicada_compra_directa()
from public, anon, authenticated;


drop trigger if exists
retenciones_practicadas_validar_compra_directa
on public.retenciones_practicadas;


create trigger
retenciones_practicadas_validar_compra_directa
before insert or update
on public.retenciones_practicadas
for each row
execute function
public.__drito_validar_retencion_practicada_compra_directa();


-- =============================================================
-- 3. APLICACIONES DE RETENCIONES AGRUPADAS
-- =============================================================
--
-- Un pago PPR puede cancelar varias compras.
--
-- Una sola retención/certificado también puede corresponder a
-- ese PPR completo.
--
-- Por eso NO duplicamos el certificado.
--
-- La retención vive una sola vez en:
--
--   retenciones_practicadas
--
-- y esta tabla indica cuánto de esa retención cancela cada
-- compra.
-- =============================================================

create table if not exists
public.retenciones_practicadas_aplicaciones (

  id uuid primary key
    default gen_random_uuid(),


  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,


  retencion_id uuid not null
    references public.retenciones_practicadas(id)
    on delete restrict,


  compra_id uuid not null
    references public.compras(id)
    on delete restrict,


  importe_aplicado numeric(18,2) not null
    check (
      importe_aplicado > 0
    ),


  creado_por uuid
    references auth.users(id)
    on delete set null,


  created_at timestamptz not null
    default now(),


  unique (
    retencion_id,
    compra_id
  )
);


comment on table
public.retenciones_practicadas_aplicaciones is
  'Distribución de una retención practicada agrupada entre las compras cuya deuda comercial cancela. No representa dinero de Caja.';


comment on column
public.retenciones_practicadas_aplicaciones.importe_aplicado is
  'Porción de la retención practicada que cancela deuda de una compra determinada.';


create index if not exists
retenciones_practicadas_aplicaciones_compra_idx
on public.retenciones_practicadas_aplicaciones (
  compra_id
);


create index if not exists
retenciones_practicadas_aplicaciones_comercio_idx
on public.retenciones_practicadas_aplicaciones (
  comercio_id,
  compra_id
);


-- =============================================================
-- 4. VALIDACIÓN DE APLICACIONES AGRUPADAS
-- =============================================================

create or replace function
public.__drito_validar_aplicacion_retencion_practicada()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare

  v_retencion
    public.retenciones_practicadas%rowtype;

  v_comercio_compra uuid;
  v_proveedor_compra uuid;
  v_estado_compra text;

  v_aplicado_actual numeric(18,2);

begin

  select r.*
  into v_retencion
  from public.retenciones_practicadas as r
  where r.id = new.retencion_id;


  if not found then
    raise exception
      'Retención practicada inexistente';
  end if;


  -- Esta tabla solamente distribuye retenciones agrupadas PPR.
  if v_retencion.pago_proveedor_id is null then
    raise exception
      'La aplicación por compras solo corresponde a retenciones de pagos agrupados';
  end if;


  if
    v_retencion.compra_id is not null
    or v_retencion.pago_compra_id is not null
  then
    raise exception
      'La retención indicada no corresponde a un pago agrupado';
  end if;


  if v_retencion.estado <> 'registrada' then
    raise exception
      'No se puede aplicar una retención anulada';
  end if;


  if new.comercio_id <> v_retencion.comercio_id then
    raise exception
      'La aplicación y la retención pertenecen a comercios diferentes';
  end if;


  select
    c.comercio_id,
    c.proveedor_id,
    c.estado
  into
    v_comercio_compra,
    v_proveedor_compra,
    v_estado_compra
  from public.compras as c
  where c.id = new.compra_id;


  if not found then
    raise exception
      'Compra inexistente';
  end if;


  if v_comercio_compra <> new.comercio_id then
    raise exception
      'La aplicación y la compra pertenecen a comercios diferentes';
  end if;


  if v_proveedor_compra <> v_retencion.proveedor_id then
    raise exception
      'La compra pertenece a otro proveedor';
  end if;


  if v_estado_compra <> 'confirmada' then
    raise exception
      'La retención solo puede aplicarse a compras confirmadas';
  end if;


  -- ===========================================================
  -- NO SOBREPASAR EL TOTAL DE LA RETENCIÓN
  -- ===========================================================

  if tg_op = 'UPDATE' then

    select
      coalesce(
        sum(a.importe_aplicado),
        0
      )::numeric(18,2)
    into v_aplicado_actual
    from public.retenciones_practicadas_aplicaciones as a
    where a.retencion_id = new.retencion_id
      and a.id <> old.id;

  else

    select
      coalesce(
        sum(a.importe_aplicado),
        0
      )::numeric(18,2)
    into v_aplicado_actual
    from public.retenciones_practicadas_aplicaciones as a
    where a.retencion_id = new.retencion_id;

  end if;


  if
    round(
      v_aplicado_actual
      + new.importe_aplicado,
      2
    )
    >
    round(
      v_retencion.importe,
      2
    )
  then
    raise exception
      'Las aplicaciones superan el importe total de la retención';
  end if;


  if new.creado_por is null then
    new.creado_por := auth.uid();
  end if;


  return new;

end;
$$;


revoke all
on function
public.__drito_validar_aplicacion_retencion_practicada()
from public, anon, authenticated;


drop trigger if exists
retenciones_practicadas_aplicaciones_validar
on public.retenciones_practicadas_aplicaciones;


create trigger
retenciones_practicadas_aplicaciones_validar
before insert or update
on public.retenciones_practicadas_aplicaciones
for each row
execute function
public.__drito_validar_aplicacion_retencion_practicada();


-- =============================================================
-- 5. MOTOR CENTRAL DE CANCELACIÓN DE UNA COMPRA
-- =============================================================

create or replace function
public.__drito_calcular_cancelacion_compra(
  p_compra_id uuid
)
returns table (

  compra_id uuid,

  total_compra numeric,

  dinero_pagado numeric,

  retenciones_directas numeric,

  retenciones_agrupadas numeric,

  retenciones_practicadas numeric,

  total_cancelado numeric,

  saldo_pendiente numeric,

  estado_pago text

)
language plpgsql
security definer
set search_path = public
as $$
declare

  v_total_compra numeric(18,2);

  v_dinero numeric(18,2);

  v_retenciones_directas numeric(18,2);

  v_retenciones_agrupadas numeric(18,2);

  v_total_retenciones numeric(18,2);

  v_total_cancelado numeric(18,2);

  v_saldo numeric(18,2);

  v_estado text;

begin

  if p_compra_id is null then
    raise exception
      'La compra es obligatoria';
  end if;


  select
    round(c.total, 2)
  into v_total_compra
  from public.compras as c
  where c.id = p_compra_id;


  if not found then
    raise exception
      'Compra no encontrada';
  end if;


  -- ===========================================================
  -- DINERO REAL
  --
  -- Incluye:
  --
  --   PAG individual
  --   PAG interno generado por PPR
  --
  -- Ambos representan dinero realmente pagado.
  --
  -- Caja sigue manejándose mediante sus mecanismos actuales.
  -- ===========================================================

  select
    coalesce(
      sum(
        round(pc.importe, 2)
      ),
      0
    )::numeric(18,2)
  into v_dinero
  from public.pagos_compras as pc
  where pc.compra_id = p_compra_id
    and pc.estado = 'registrado';


  -- ===========================================================
  -- RETENCIONES DIRECTAS
  -- ===========================================================

  select
    coalesce(
      sum(
        round(r.importe, 2)
      ),
      0
    )::numeric(18,2)
  into v_retenciones_directas
  from public.retenciones_practicadas as r
  where r.compra_id = p_compra_id
    and r.estado = 'registrada';


  -- ===========================================================
  -- RETENCIONES AGRUPADAS PPR
  -- ===========================================================

  select
    coalesce(
      sum(
        round(a.importe_aplicado, 2)
      ),
      0
    )::numeric(18,2)
  into v_retenciones_agrupadas
  from public.retenciones_practicadas_aplicaciones as a

  inner join public.retenciones_practicadas as r
    on r.id = a.retencion_id

  where a.compra_id = p_compra_id
    and r.estado = 'registrada';


  v_total_retenciones :=
    round(
      v_retenciones_directas
      + v_retenciones_agrupadas,
      2
    );


  v_total_cancelado :=
    round(
      v_dinero
      + v_total_retenciones,
      2
    );


  v_saldo :=
    greatest(
      round(
        v_total_compra
        - v_total_cancelado,
        2
      ),
      0
    );


  v_estado :=
    case

      when v_saldo <= 0
        then 'pagada'

      when v_total_cancelado > 0
        then 'parcial'

      else 'pendiente'

    end;


  return query
  select

    p_compra_id,

    v_total_compra,

    v_dinero,

    v_retenciones_directas,

    v_retenciones_agrupadas,

    v_total_retenciones,

    v_total_cancelado,

    v_saldo,

    v_estado;

end;
$$;


revoke all
on function
public.__drito_calcular_cancelacion_compra(uuid)
from public, anon, authenticated;


-- =============================================================
-- 6. SINCRONIZAR RESUMEN GUARDADO EN COMPRAS
-- =============================================================

create or replace function
public.__drito_sincronizar_cancelacion_compra(
  p_compra_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare

  v_estado_compra text;

  v_resumen record;

begin

  if p_compra_id is null then
    return;
  end if;


  select c.estado
  into v_estado_compra
  from public.compras as c
  where c.id = p_compra_id
  for update;


  if not found then
    return;
  end if;


  if v_estado_compra <> 'confirmada' then
    return;
  end if;


  select *
  into v_resumen
  from public.__drito_calcular_cancelacion_compra(
    p_compra_id
  );


  update public.compras as c
  set

    total_pagado =
      v_resumen.total_cancelado,

    estado_pago =
      v_resumen.estado_pago

  where c.id = p_compra_id;


  -- Algunas instalaciones históricas pueden tener almacenado
  -- saldo_pendiente y otras calcularlo dinámicamente.
  -- Solo lo actualizamos si la columna existe.

  if exists (

    select 1

    from information_schema.columns

    where table_schema = 'public'

      and table_name = 'compras'

      and column_name = 'saldo_pendiente'

  ) then

    execute '
      update public.compras
      set saldo_pendiente = $1
      where id = $2
    '
    using
      v_resumen.saldo_pendiente,
      p_compra_id;

  end if;

end;
$$;


revoke all
on function
public.__drito_sincronizar_cancelacion_compra(uuid)
from public, anon, authenticated;


-- =============================================================
-- 7. COMPATIBILIDAD CON EL HELPER HISTÓRICO
-- =============================================================
--
-- Los módulos anteriores ya llaman:
--
--   actualizar_resumen_pago_compra(uuid)
--
-- Conservamos exactamente la misma firma.
--
-- Desde ahora ese helper utiliza el motor central.
-- =============================================================

create or replace function
public.actualizar_resumen_pago_compra(
  p_compra_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin

  perform
    public.__drito_sincronizar_cancelacion_compra(
      p_compra_id
    );

end;
$$;


revoke all
on function
public.actualizar_resumen_pago_compra(uuid)
from public, anon, authenticated;


-- =============================================================
-- 8. PROTEGER compras.total_pagado / estado_pago
-- =============================================================
--
-- Si una función histórica intenta grabar solamente el dinero
-- como total pagado, este trigger vuelve a calcular:
--
-- dinero + retenciones.
-- =============================================================

create or replace function
public.__drito_normalizar_resumen_cancelacion_compra()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare

  v_resumen record;

begin

  if new.estado <> 'confirmada' then
    return new;
  end if;


  select *
  into v_resumen
  from public.__drito_calcular_cancelacion_compra(
    new.id
  );


  new.total_pagado :=
    v_resumen.total_cancelado;


  new.estado_pago :=
    v_resumen.estado_pago;


  return new;

end;
$$;


revoke all
on function
public.__drito_normalizar_resumen_cancelacion_compra()
from public, anon, authenticated;


drop trigger if exists
compras_normalizar_resumen_cancelacion
on public.compras;


create trigger
compras_normalizar_resumen_cancelacion
before update of
  total_pagado,
  estado_pago
on public.compras
for each row
execute function
public.__drito_normalizar_resumen_cancelacion_compra();


-- =============================================================
-- 9. SINCRONIZAR CUANDO CAMBIA UN PAGO DE COMPRA
-- =============================================================

create or replace function
public.__drito_pago_compra_sincronizar_compra()
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


  if v_compra_anterior is not null then

    perform
      public.__drito_sincronizar_cancelacion_compra(
        v_compra_anterior
      );

  end if;


  if
    v_compra_nueva is not null
    and v_compra_nueva
      is distinct from
      v_compra_anterior
  then

    perform
      public.__drito_sincronizar_cancelacion_compra(
        v_compra_nueva
      );

  end if;


  if tg_op = 'DELETE' then
    return old;
  end if;


  return new;

end;
$$;


revoke all
on function
public.__drito_pago_compra_sincronizar_compra()
from public, anon, authenticated;


drop trigger if exists
pagos_compras_sincronizar_compra
on public.pagos_compras;


create trigger
pagos_compras_sincronizar_compra
after insert or update or delete
on public.pagos_compras
for each row
execute function
public.__drito_pago_compra_sincronizar_compra();


-- =============================================================
-- 10. SINCRONIZAR RETENCIÓN DIRECTA O AGRUPADA
-- =============================================================

create or replace function
public.__drito_retencion_practicada_sincronizar_compra()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare

  v_compra uuid;

begin

  -- ===========================================================
  -- RELACIONES ANTERIORES
  -- ===========================================================

  if tg_op in (
    'UPDATE',
    'DELETE'
  ) then

    if old.compra_id is not null then

      perform
        public.__drito_sincronizar_cancelacion_compra(
          old.compra_id
        );

    end if;


    for v_compra in

      select distinct
        a.compra_id

      from public.retenciones_practicadas_aplicaciones as a

      where a.retencion_id = old.id

    loop

      perform
        public.__drito_sincronizar_cancelacion_compra(
          v_compra
        );

    end loop;

  end if;


  -- ===========================================================
  -- RELACIONES NUEVAS
  -- ===========================================================

  if tg_op in (
    'INSERT',
    'UPDATE'
  ) then

    if new.compra_id is not null then

      perform
        public.__drito_sincronizar_cancelacion_compra(
          new.compra_id
        );

    end if;


    for v_compra in

      select distinct
        a.compra_id

      from public.retenciones_practicadas_aplicaciones as a

      where a.retencion_id = new.id

    loop

      perform
        public.__drito_sincronizar_cancelacion_compra(
          v_compra
        );

    end loop;

  end if;


  if tg_op = 'DELETE' then
    return old;
  end if;


  return new;

end;
$$;


revoke all
on function
public.__drito_retencion_practicada_sincronizar_compra()
from public, anon, authenticated;


drop trigger if exists
retenciones_practicadas_sincronizar_compra
on public.retenciones_practicadas;


create trigger
retenciones_practicadas_sincronizar_compra
after insert or update or delete
on public.retenciones_practicadas
for each row
execute function
public.__drito_retencion_practicada_sincronizar_compra();


-- =============================================================
-- 11. SINCRONIZAR APLICACIONES AGRUPADAS
-- =============================================================

create or replace function
public.__drito_aplicacion_retencion_sincronizar_compra()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin

  if tg_op in (
    'UPDATE',
    'DELETE'
  ) then

    perform
      public.__drito_sincronizar_cancelacion_compra(
        old.compra_id
      );

  end if;


  if
    tg_op in (
      'INSERT',
      'UPDATE'
    )
    and (
      tg_op = 'INSERT'
      or new.compra_id
        is distinct from
        old.compra_id
    )
  then

    perform
      public.__drito_sincronizar_cancelacion_compra(
        new.compra_id
      );

  elsif tg_op = 'UPDATE' then

    -- Si solamente cambió el importe aplicado también
    -- debemos recalcular la misma compra.

    perform
      public.__drito_sincronizar_cancelacion_compra(
        new.compra_id
      );

  end if;


  if tg_op = 'DELETE' then
    return old;
  end if;


  return new;

end;
$$;


revoke all
on function
public.__drito_aplicacion_retencion_sincronizar_compra()
from public, anon, authenticated;


drop trigger if exists
retenciones_practicadas_aplicaciones_sincronizar
on public.retenciones_practicadas_aplicaciones;


create trigger
retenciones_practicadas_aplicaciones_sincronizar
after insert or update or delete
on public.retenciones_practicadas_aplicaciones
for each row
execute function
public.__drito_aplicacion_retencion_sincronizar_compra();


-- =============================================================
-- 12. SEGURIDAD DE APLICACIONES
-- =============================================================

alter table
public.retenciones_practicadas_aplicaciones
enable row level security;


drop policy if exists
retenciones_practicadas_aplicaciones_select
on public.retenciones_practicadas_aplicaciones;


create policy
retenciones_practicadas_aplicaciones_select
on public.retenciones_practicadas_aplicaciones
for select
to authenticated
using (

  public.tiene_permiso_comercio(
    comercio_id,
    'cuentas_proveedores.ver'
  )

  or

  public.tiene_permiso_comercio(
    comercio_id,
    'compras.ver'
  )

);


revoke all
on table
public.retenciones_practicadas_aplicaciones
from anon;


revoke insert, update, delete
on table
public.retenciones_practicadas_aplicaciones
from authenticated;


grant select
on table
public.retenciones_practicadas_aplicaciones
to authenticated;


notify pgrst, 'reload schema';


commit;


-- =============================================================
-- FIN PASO 12B.2.2
-- =============================================================