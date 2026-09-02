-- ============================================================
-- DRITO
-- PASO 15A.4.2.2
-- AUDITORÍA OPERACIONAL - RETENCIONES PRACTICADAS
--
-- Audita automáticamente:
-- - registro de retención practicada;
-- - anulación de retención practicada;
-- - actualización/asociación de certificado.
--
-- Funciona para:
-- - retenciones individuales sobre compras;
-- - retenciones agrupadas sobre pagos a proveedores.
--
-- No modifica motores fiscales, pagos ni Caja.
-- ============================================================


-- ============================================================
-- 0. PRECONDICIONES
-- ============================================================

do $$
begin

  if to_regclass(
    'public.retenciones_practicadas'
  ) is null then
    raise exception
      'Falta public.retenciones_practicadas';
  end if;


  if to_regclass(
    'public.auditoria_operaciones'
  ) is null then
    raise exception
      'Falta public.auditoria_operaciones';
  end if;


  if to_regprocedure(
    'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
  ) is null then
    raise exception
      'Falta el helper de auditoría operacional';
  end if;

end;
$$;


-- ============================================================
-- 1. FUNCIÓN INTERNA DE AUDITORÍA
-- ============================================================

create or replace function
public.__drito_auditar_retencion_practicada()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$

declare

  v_modulo text;

  v_origen text;

  v_referencia text;

  v_motivo text;

begin

  -- ==========================================================
  -- ORIGEN
  -- ==========================================================

  if new.pago_proveedor_id is not null then

    v_origen :=
      'agrupada';

    v_modulo :=
      'cuentas_proveedores';

  else

    v_origen :=
      'individual';

    v_modulo :=
      'compras';

  end if;


  v_referencia :=
    nullif(
      trim(
        coalesce(
          new.numero_certificado,
          ''
        )
      ),
      ''
    );


  -- ==========================================================
  -- 2. ALTA
  -- ==========================================================

  if tg_op = 'INSERT' then

    perform public.__drito_registrar_auditoria_operacion(
      p_comercio_id  => new.comercio_id,
      p_modulo       => v_modulo,
      p_accion       => 'retencion_practicada_registrada',
      p_entidad_tipo => 'retencion_practicada',
      p_entidad_id   => new.id::text,
      p_referencia   => v_referencia,
      p_detalle      => jsonb_build_object(

        'origen',
          v_origen,

        'proveedor_id',
          new.proveedor_id,

        'compra_id',
          new.compra_id,

        'pago_compra_id',
          new.pago_compra_id,

        'pago_proveedor_id',
          new.pago_proveedor_id,

        'configuracion_agente_id',
          new.configuracion_agente_id,

        'fecha_retencion',
          new.fecha_retencion,

        'numero_certificado',
          new.numero_certificado,

        'base_calculo',
          new.base_calculo,

        'alicuota',
          new.alicuota,

        'importe',
          new.importe,

        'moneda',
          new.moneda,

        'estado',
          new.estado,

        'estado_obligacion',
          new.estado_obligacion

      )
    );


    return new;

  end if;


  -- ==========================================================
  -- 3. ANULACIÓN
  -- ==========================================================

  if tg_op = 'UPDATE'
     and old.estado is distinct from new.estado
     and new.estado = 'anulada' then


    v_motivo :=
      nullif(
        trim(
          coalesce(
            to_jsonb(new)->>'motivo_anulacion',
            ''
          )
        ),
        ''
      );


    perform public.__drito_registrar_auditoria_operacion(
      p_comercio_id  => new.comercio_id,
      p_modulo       => v_modulo,
      p_accion       => 'retencion_practicada_anulada',
      p_entidad_tipo => 'retencion_practicada',
      p_entidad_id   => new.id::text,
      p_referencia   => v_referencia,
      p_detalle      => jsonb_build_object(

        'origen',
          v_origen,

        'proveedor_id',
          new.proveedor_id,

        'compra_id',
          new.compra_id,

        'pago_compra_id',
          new.pago_compra_id,

        'pago_proveedor_id',
          new.pago_proveedor_id,

        'numero_certificado',
          new.numero_certificado,

        'importe',
          new.importe,

        'moneda',
          new.moneda,

        'estado_anterior',
          old.estado,

        'estado_nuevo',
          new.estado,

        'estado_obligacion_anterior',
          old.estado_obligacion,

        'estado_obligacion_nuevo',
          new.estado_obligacion,

        'motivo',
          v_motivo,

        'anulado_por',
          to_jsonb(new)->>'anulado_por',

        'anulado_at',
          to_jsonb(new)->>'anulado_at'

      )
    );

  end if;


  -- ==========================================================
  -- 4. CERTIFICADO
  -- ==========================================================

  if tg_op = 'UPDATE'
     and (
       old.numero_certificado
         is distinct from
         new.numero_certificado

       or

       old.certificado_storage_path
         is distinct from
         new.certificado_storage_path
     ) then


    v_referencia :=
      nullif(
        trim(
          coalesce(
            new.numero_certificado,
            ''
          )
        ),
        ''
      );


    perform public.__drito_registrar_auditoria_operacion(
      p_comercio_id  => new.comercio_id,
      p_modulo       => v_modulo,
      p_accion       => 'certificado_retencion_actualizado',
      p_entidad_tipo => 'retencion_practicada',
      p_entidad_id   => new.id::text,
      p_referencia   => v_referencia,
      p_detalle      => jsonb_build_object(

        'origen',
          v_origen,

        'proveedor_id',
          new.proveedor_id,

        'compra_id',
          new.compra_id,

        'pago_compra_id',
          new.pago_compra_id,

        'pago_proveedor_id',
          new.pago_proveedor_id,

        'numero_certificado_anterior',
          old.numero_certificado,

        'numero_certificado_nuevo',
          new.numero_certificado,

        'archivo_anterior',
          old.certificado_storage_path,

        'archivo_nuevo',
          new.certificado_storage_path

      )
    );

  end if;


  return new;

end;
$function$;


-- ============================================================
-- 5. FUNCIÓN EXCLUSIVAMENTE INTERNA
-- ============================================================

revoke all on function
public.__drito_auditar_retencion_practicada()
from public, anon, authenticated;


-- ============================================================
-- 6. TRIGGER
-- ============================================================

drop trigger if exists
retenciones_practicadas_auditoria_operacional
on public.retenciones_practicadas;


create trigger
retenciones_practicadas_auditoria_operacional
after insert
or update of
  estado,
  estado_obligacion,
  numero_certificado,
  certificado_storage_path
on public.retenciones_practicadas
for each row
execute function
public.__drito_auditar_retencion_practicada();


-- ============================================================
-- 7. VERIFICACIÓN ESTRUCTURAL
-- ============================================================

select jsonb_build_object(

  'tabla_retenciones',
    to_regclass(
      'public.retenciones_practicadas'
    ) is not null,

  'tabla_auditoria',
    to_regclass(
      'public.auditoria_operaciones'
    ) is not null,

  'helper_auditoria',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'funcion_trigger',
    to_regprocedure(
      'public.__drito_auditar_retencion_practicada()'
    ) is not null,

  'trigger_instalado',
    exists (
      select 1
      from pg_trigger tg
      where tg.tgrelid =
        'public.retenciones_practicadas'::regclass

        and tg.tgname =
          'retenciones_practicadas_auditoria_operacional'

        and not tg.tgisinternal
    ),

  'anular_retencion_existe',
    to_regprocedure(
      'public.anular_retencion_practicada(uuid,text)'
    ) is not null,

  'guardar_certificado_existe',
    to_regprocedure(
      'public.guardar_certificado_retencion_practicada(uuid,text,text)'
    ) is not null,

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a4_2_2;