-- ============================================================
-- DRITO
-- PASO 13A.1 - MODELO FISCAL DE IVA EN COMPRAS
-- Archivo: 52_paso13a1_modelo_iva_compras.sql
--
-- Objetivo:
--   Agregar clasificación fiscal de IVA a nivel de ítem de compra
--   sin alterar los importes comerciales históricos ni inferir
--   tratamientos fiscales que nunca fueron registrados.
--
-- Reglas:
--   - El tratamiento fiscal vive en items_compra.
--   - NULL en iva_tratamiento = histórico / todavía no clasificado.
--   - No se convierte automáticamente IVA 21% en "computable".
--   - iva_alicuota_codigo referencia el catálogo ARCA existente.
--   - exento / no_gravado no llevan IVA ni código de alícuota.
--   - Caja no se modifica.
--   - compras.total / compras.impuestos no se recalculan aquí.
--   - No se modifica stock, pagos, retenciones ni percepciones.
-- ============================================================

begin;

-- ============================================================
-- 1. PRECONDICIONES
-- ============================================================

do $$
begin
  if to_regclass('public.items_compra') is null then
    raise exception
      'No existe public.items_compra';
  end if;

  if to_regclass('public.compras') is null then
    raise exception
      'No existe public.compras';
  end if;

  if to_regclass('public.arca_alicuotas_iva') is null then
    raise exception
      'No existe public.arca_alicuotas_iva';
  end if;
end;
$$;

-- ============================================================
-- 2. COLUMNAS FISCALES EN ITEMS_COMPRA
-- ============================================================

alter table public.items_compra
  add column if not exists iva_tratamiento text null;

alter table public.items_compra
  add column if not exists iva_alicuota_codigo smallint null;

alter table public.items_compra
  add column if not exists iva_base_fiscal numeric(14,2) null;

comment on column public.items_compra.iva_tratamiento is
  'Tratamiento fiscal del IVA de compras: computable, no_computable, exento o no_gravado. NULL significa histórico/no clasificado y no debe inferirse automáticamente.';

comment on column public.items_compra.iva_alicuota_codigo is
  'Código de alícuota IVA del catálogo public.arca_alicuotas_iva cuando el ítem está gravado. Para exento/no_gravado debe ser NULL.';

comment on column public.items_compra.iva_base_fiscal is
  'Base fiscal del ítem utilizada para el tratamiento de IVA. Se mantiene separada de neto para permitir futuras reglas de descuentos fiscales sin alterar el total comercial histórico.';

-- ============================================================
-- 3. CONSTRAINTS
-- ============================================================

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.items_compra'::regclass
      and conname = 'items_compra_iva_tratamiento_check'
  ) then
    alter table public.items_compra
      add constraint items_compra_iva_tratamiento_check
      check (
        iva_tratamiento is null
        or iva_tratamiento in (
          'computable',
          'no_computable',
          'exento',
          'no_gravado'
        )
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.items_compra'::regclass
      and conname = 'items_compra_iva_base_fiscal_check'
  ) then
    alter table public.items_compra
      add constraint items_compra_iva_base_fiscal_check
      check (
        iva_base_fiscal is null
        or iva_base_fiscal >= 0
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.items_compra'::regclass
      and conname = 'items_compra_iva_alicuota_codigo_fkey'
  ) then
    alter table public.items_compra
      add constraint items_compra_iva_alicuota_codigo_fkey
      foreign key (iva_alicuota_codigo)
      references public.arca_alicuotas_iva(codigo)
      on update restrict
      on delete restrict;
  end if;
end;
$$;

-- ============================================================
-- 4. BACKFILL OBJETIVO DE DATOS HISTÓRICOS
-- ============================================================
--
-- Sí podemos completar:
--   - la base fiscal histórica desde items_compra.neto;
--   - el código ARCA cuando existe una coincidencia exacta
--     y única por porcentaje activo.
--
-- NO completamos iva_tratamiento porque eso implicaría decidir
-- si el crédito era computable/no computable/exento/no gravado
-- sin información histórica suficiente.
-- ============================================================

update public.items_compra as i
set
  iva_base_fiscal = i.neto
where i.iva_base_fiscal is null;

update public.items_compra as i
set
  iva_alicuota_codigo = catalogo.codigo
from (
  select
    a.porcentaje,
    min(a.codigo) as codigo
  from public.arca_alicuotas_iva as a
  where a.activo = true
    and a.porcentaje is not null
  group by a.porcentaje
  having count(*) = 1
) as catalogo
where i.iva_alicuota_codigo is null
  and i.iva_porcentaje = catalogo.porcentaje;

-- ============================================================
-- 5. VALIDACIÓN DE INTEGRIDAD PARA FILAS CLASIFICADAS
-- ============================================================

create or replace function public.__drito_validar_iva_item_compra()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_porcentaje_catalogo numeric;
  v_activo boolean;
  v_impuesto_esperado numeric(14,2);
begin
  if new.iva_base_fiscal is null then
    new.iva_base_fiscal := new.neto;
  end if;

  if new.iva_base_fiscal < 0 then
    raise exception
      'La base fiscal de IVA no puede ser negativa';
  end if;

  -- Compatibilidad histórica/transicional.
  -- Una fila sin clasificación conserva su comportamiento actual.
  if new.iva_tratamiento is null then
    return new;
  end if;

  if new.iva_tratamiento in (
    'exento',
    'no_gravado'
  ) then
    if coalesce(new.iva_porcentaje, 0) <> 0 then
      raise exception
        'Un ítem % debe tener IVA 0%%',
        new.iva_tratamiento;
    end if;

    if coalesce(new.impuesto_importe, 0) <> 0 then
      raise exception
        'Un ítem % no puede tener importe de IVA',
        new.iva_tratamiento;
    end if;

    if new.iva_alicuota_codigo is not null then
      raise exception
        'Un ítem % no debe tener código de alícuota IVA',
        new.iva_tratamiento;
    end if;

    return new;
  end if;

  -- computable / no_computable
  if new.iva_alicuota_codigo is null then
    raise exception
      'Un ítem con IVA % debe indicar código de alícuota ARCA',
      new.iva_tratamiento;
  end if;

  select
    a.porcentaje,
    a.activo
  into
    v_porcentaje_catalogo,
    v_activo
  from public.arca_alicuotas_iva as a
  where a.codigo = new.iva_alicuota_codigo;

  if not found then
    raise exception
      'Código de alícuota IVA inexistente: %',
      new.iva_alicuota_codigo;
  end if;

  if v_activo is not true then
    raise exception
      'La alícuota IVA seleccionada se encuentra inactiva';
  end if;

  if v_porcentaje_catalogo is null then
    raise exception
      'La alícuota IVA seleccionada no posee porcentaje';
  end if;

  if round(new.iva_porcentaje, 4)
     <> round(v_porcentaje_catalogo, 4) then
    raise exception
      'El porcentaje IVA (%) no coincide con el código ARCA % (%)',
      new.iva_porcentaje,
      new.iva_alicuota_codigo,
      v_porcentaje_catalogo;
  end if;

  v_impuesto_esperado :=
    round(
      new.iva_base_fiscal
      * new.iva_porcentaje
      / 100,
      2
    );

  if round(new.impuesto_importe, 2)
     <> v_impuesto_esperado then
    raise exception
      'El importe IVA (%) no coincide con base fiscal (%) x alícuota (%)',
      new.impuesto_importe,
      new.iva_base_fiscal,
      new.iva_porcentaje;
  end if;

  return new;
end;
$function$;

drop trigger if exists
  items_compra_validar_iva_fiscal
on public.items_compra;

create trigger items_compra_validar_iva_fiscal
before insert or update of
  neto,
  iva_porcentaje,
  impuesto_importe,
  iva_tratamiento,
  iva_alicuota_codigo,
  iva_base_fiscal
on public.items_compra
for each row
execute function public.__drito_validar_iva_item_compra();

comment on function public.__drito_validar_iva_item_compra() is
  'Valida coherencia fiscal del IVA en items de compra. Permite NULL en iva_tratamiento para compatibilidad histórica; las filas clasificadas deben respetar catálogo ARCA y tratamiento.';

-- ============================================================
-- 6. ÍNDICES
-- ============================================================

create index if not exists
  items_compra_comercio_iva_tratamiento_idx
on public.items_compra (
  comercio_id,
  iva_tratamiento
);

create index if not exists
  items_compra_iva_alicuota_codigo_idx
on public.items_compra (
  iva_alicuota_codigo
);

-- ============================================================
-- 7. SEGURIDAD DE HELPER INTERNO
-- ============================================================

revoke all
on function public.__drito_validar_iva_item_compra()
from public;

revoke all
on function public.__drito_validar_iva_item_compra()
from anon;

revoke all
on function public.__drito_validar_iva_item_compra()
from authenticated;

-- ============================================================
-- 8. ASSERTIONS DE MIGRACIÓN
-- ============================================================

do $$
declare
  v_total_items bigint;
  v_items_sin_base bigint;
  v_tratamientos_inventados bigint;
  v_items_21 bigint;
  v_items_21_codigo_5 bigint;
begin
  select count(*)
  into v_total_items
  from public.items_compra;

  select count(*)
  into v_items_sin_base
  from public.items_compra
  where iva_base_fiscal is null;

  if v_items_sin_base <> 0 then
    raise exception
      'Migración incompleta: quedaron % ítems sin base fiscal',
      v_items_sin_base;
  end if;

  select count(*)
  into v_tratamientos_inventados
  from public.items_compra
  where iva_tratamiento is not null;

  if v_tratamientos_inventados <> 0 then
    raise exception
      'La migración no debe clasificar automáticamente compras históricas. Filas clasificadas: %',
      v_tratamientos_inventados;
  end if;

  -- En el estado diagnosticado antes de esta migración todos los
  -- ítems históricos eran 21%. Si ese estado cambió entre el
  -- diagnóstico y la ejecución, no bloqueamos la migración;
  -- solo comprobamos que cualquier 21% mapeado use el código 5
  -- cuando dicho código siga representando 21%.
  if exists (
    select 1
    from public.arca_alicuotas_iva
    where codigo = 5
      and activo = true
      and porcentaje = 21
  ) then
    select count(*)
    into v_items_21
    from public.items_compra
    where iva_porcentaje = 21;

    select count(*)
    into v_items_21_codigo_5
    from public.items_compra
    where iva_porcentaje = 21
      and iva_alicuota_codigo = 5;

    if v_items_21 <> v_items_21_codigo_5 then
      raise exception
        'No todos los ítems IVA 21%% quedaron asociados al código ARCA 5';
    end if;
  end if;
end;
$$;

commit;
