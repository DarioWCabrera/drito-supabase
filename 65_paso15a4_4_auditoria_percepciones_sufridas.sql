-- ============================================================
-- DRITO
-- PASO 15A.4.4
-- AUDITORÍA OPERACIONAL - PERCEPCIONES SUFRIDAS
--
-- Audita automáticamente:
-- - registro de percepción sufrida;
-- - anulación de percepción sufrida.
--
-- No modifica:
-- - motor de compras;
-- - total comercial;
-- - recálculo de percepciones;
-- - pagos;
-- - retenciones;
-- - Caja.
-- ============================================================


-- ============================================================
-- 0. PRECONDICIONES
-- ============================================================

do $$
begin

  if to_regclass(
    'public.percepciones_sufridas'
  ) is null then
    raise exception
      'Falta public.percepciones_sufridas';
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


  if to_regprocedure(
    'public.__drito_registrar_percepciones_sufridas_compra(uuid,jsonb)'
  ) is null then
    raise exception
      'Falta el motor de alta de percepciones sufridas';
  end if;


  if to_regprocedure(
    'public.anular_percepcion_sufrida(uuid,text)'
  ) is null then
    raise exception
      'Falta anular_percepcion_sufrida';
  end if;

end;
$$;


-- ============================================================
-- 1. FUNCIÓN INTERNA DE AUDITORÍA
-- ============================================================

create or replace function
public.__drito_auditar_percepcion_sufrida()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$

declare

  v_referencia text;

  v_motivo text;

begin

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

      p_comercio_id =>
        new.comercio_id,

      p_modulo =>
        'compras',

      p_accion =>
        'percepcion_sufrida_registrada',

      p_entidad_tipo =>
        'percepcion_sufrida',

      p_entidad_id =>
        new.id::text,

      p_referencia =>
        v_referencia,

      p_detalle =>
        jsonb_build_object(

          'compra_id',
            new.compra_id,

          'proveedor_id',
            new.proveedor_id,

          'fecha_percepcion',
            new.fecha_percepcion,

          'organismo',
            new.organismo,

          'impuesto',
            new.impuesto,

          'jurisdiccion',
            new.jurisdiccion,

          'regimen_codigo',
            new.regimen_codigo,

          'regimen_descripcion',
            new.regimen_descripcion,

          'numero_inscripcion_agente',
            new.numero_inscripcion_agente,

          'base_calculo',
            new.base_calculo,

          'alicuota',
            new.alicuota,

          'importe',
            new.importe,

          'moneda',
            new.moneda,

          'numero_certificado',
            new.numero_certificado,

          'certificado_storage_path',
            new.certificado_storage_path,

          'estado',
            new.estado

        )

    );


    return new;

  end if;


  -- ==========================================================
  -- 3. ANULACIÓN
  -- ==========================================================

  if tg_op = 'UPDATE'
     and old.estado is distinct from new.estado
     and new.estado = 'anulada'
  then

    v_motivo :=
      nullif(
        trim(
          coalesce(
            to_jsonb(new)
              ->> 'motivo_anulacion',
            ''
          )
        ),
        ''
      );


    perform public.__drito_registrar_auditoria_operacion(

      p_comercio_id =>
        new.comercio_id,

      p_modulo =>
        'compras',

      p_accion =>
        'percepcion_sufrida_anulada',

      p_entidad_tipo =>
        'percepcion_sufrida',

      p_entidad_id =>
        new.id::text,

      p_referencia =>
        v_referencia,

      p_detalle =>
        jsonb_build_object(

          'compra_id',
            new.compra_id,

          'proveedor_id',
            new.proveedor_id,

          'fecha_percepcion',
            new.fecha_percepcion,

          'organismo',
            new.organismo,

          'impuesto',
            new.impuesto,

          'jurisdiccion',
            new.jurisdiccion,

          'regimen_codigo',
            new.regimen_codigo,

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

          'motivo',
            v_motivo,

          'anulado_por',
            to_jsonb(new)
              ->> 'anulado_por',

          'anulado_at',
            to_jsonb(new)
              ->> 'anulado_at'

        )

    );

  end if;


  return new;

end;
$function$;


-- ============================================================
-- 4. FUNCIÓN EXCLUSIVAMENTE INTERNA
-- ============================================================

revoke all on function
public.__drito_auditar_percepcion_sufrida()
from public, anon, authenticated;


-- ============================================================
-- 5. TRIGGER
-- ============================================================

drop trigger if exists
percepciones_sufridas_auditoria_operacional
on public.percepciones_sufridas;


create trigger
percepciones_sufridas_auditoria_operacional
after insert
or update of estado
on public.percepciones_sufridas
for each row
execute function
public.__drito_auditar_percepcion_sufrida();


-- ============================================================
-- 6. RECARGA POSTGREST
-- ============================================================

notify pgrst, 'reload schema';


-- ============================================================
-- 7. VERIFICACIÓN ESTRUCTURAL
-- ============================================================

select jsonb_build_object(

  'tabla_percepciones',
    to_regclass(
      'public.percepciones_sufridas'
    ) is not null,

  'tabla_auditoria',
    to_regclass(
      'public.auditoria_operaciones'
    ) is not null,

  'helper_auditoria',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'motor_alta_percepciones',
    to_regprocedure(
      'public.__drito_registrar_percepciones_sufridas_compra(uuid,jsonb)'
    ) is not null,

  'anular_percepcion_existe',
    to_regprocedure(
      'public.anular_percepcion_sufrida(uuid,text)'
    ) is not null,

  'funcion_trigger',
    to_regprocedure(
      'public.__drito_auditar_percepcion_sufrida()'
    ) is not null,

  'trigger_instalado',
    exists (
      select 1
      from pg_trigger tg
      where tg.tgrelid =
        'public.percepciones_sufridas'::regclass

        and tg.tgname =
          'percepciones_sufridas_auditoria_operacional'

        and not tg.tgisinternal
    ),

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a4_4;
