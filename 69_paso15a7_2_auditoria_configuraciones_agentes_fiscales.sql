-- ============================================================
-- DRITO
-- PASO 15A.7.2
-- AUDITORÍA OPERACIONAL - CONFIGURACIONES DE AGENTES FISCALES
--
-- Audita:
-- - creación;
-- - modificación;
-- - desactivación;
-- - reactivación.
--
-- No reemplaza el trigger existente que mantiene
-- created_at / updated_at / creado_por / actualizado_por.
-- ============================================================


-- ============================================================
-- 0. PRECONDICIONES
-- ============================================================

do $$
begin

  if to_regclass(
    'public.configuraciones_agentes_fiscales'
  ) is null then
    raise exception
      'Falta public.configuraciones_agentes_fiscales';
  end if;


  if to_regprocedure(
    'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
  ) is null then
    raise exception
      'Falta el helper de auditoría operacional';
  end if;


  if to_regprocedure(
    'public.guardar_configuracion_agente_fiscal(uuid,text,text,text,text,text,date,text,uuid,text,text,date,numeric,boolean,text,boolean,text)'
  ) is null then
    raise exception
      'Falta guardar_configuracion_agente_fiscal';
  end if;


  if to_regprocedure(
    'public.desactivar_configuracion_agente_fiscal(uuid,uuid)'
  ) is null then
    raise exception
      'Falta desactivar_configuracion_agente_fiscal';
  end if;

end;
$$;


-- ============================================================
-- 1. FUNCIÓN DE AUDITORÍA OPERACIONAL
-- ============================================================

create or replace function
public.__drito_auditar_configuracion_agente_fiscal()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $function$

declare

  v_accion text;

  v_referencia text;

  v_actor uuid;

  v_anterior jsonb;

  v_nuevo jsonb;

begin

  -- ==========================================================
  -- REFERENCIA LEGIBLE
  -- ==========================================================

  v_referencia :=
    coalesce(
      nullif(
        trim(
          coalesce(
            new.regimen_codigo,
            ''
          )
        ),
        ''
      ),
      nullif(
        trim(
          coalesce(
            new.regimen_descripcion,
            ''
          )
        ),
        ''
      ),
      new.id::text
    );


  v_actor :=
    coalesce(
      new.actualizado_por,
      new.creado_por,
      auth.uid()
    );


  -- ==========================================================
  -- 2. ALTA
  -- ==========================================================

  if tg_op = 'INSERT' then

    perform public.__drito_registrar_auditoria_operacion(

      p_comercio_id =>
        new.comercio_id,

      p_modulo =>
        'configuracion',

      p_accion =>
        'configuracion_agente_fiscal_creada',

      p_entidad_tipo =>
        'configuracion_agente_fiscal',

      p_entidad_id =>
        new.id::text,

      p_referencia =>
        v_referencia,

      p_detalle =>
        jsonb_build_object(

          'organismo',
            new.organismo,

          'impuesto',
            new.impuesto,

          'jurisdiccion',
            new.jurisdiccion,

          'tipo_agente',
            new.tipo_agente,

          'regimen_codigo',
            new.regimen_codigo,

          'regimen_descripcion',
            new.regimen_descripcion,

          'numero_inscripcion_agente',
            new.numero_inscripcion_agente,

          'vigencia_desde',
            new.vigencia_desde,

          'vigencia_hasta',
            new.vigencia_hasta,

          'modo_alicuota',
            new.modo_alicuota,

          'alicuota_fija',
            new.alicuota_fija,

          'requiere_certificado',
            new.requiere_certificado,

          'sistema_presentacion',
            new.sistema_presentacion,

          'activo',
            new.activo

        ),

      p_realizado_por =>
        v_actor

    );


    return new;

  end if;


  -- ==========================================================
  -- 3. IGNORAR UPDATE SIN CAMBIO FUNCIONAL
  --
  -- updated_at y actualizado_por cambian por el trigger
  -- técnico existente, por eso se excluyen de la comparación.
  -- ==========================================================

  v_anterior :=
    to_jsonb(old)
      - 'updated_at'
      - 'actualizado_por';


  v_nuevo :=
    to_jsonb(new)
      - 'updated_at'
      - 'actualizado_por';


  if v_anterior = v_nuevo then
    return new;
  end if;


  -- ==========================================================
  -- 4. DETERMINAR TIPO DE CAMBIO
  -- ==========================================================

  if old.activo = true
     and new.activo = false then

    v_accion :=
      'configuracion_agente_fiscal_desactivada';


  elsif old.activo = false
        and new.activo = true then

    v_accion :=
      'configuracion_agente_fiscal_reactivada';


  else

    v_accion :=
      'configuracion_agente_fiscal_actualizada';

  end if;


  -- ==========================================================
  -- 5. AUDITORÍA DE MODIFICACIÓN
  -- ==========================================================

  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id =>
      new.comercio_id,

    p_modulo =>
      'configuracion',

    p_accion =>
      v_accion,

    p_entidad_tipo =>
      'configuracion_agente_fiscal',

    p_entidad_id =>
      new.id::text,

    p_referencia =>
      v_referencia,

    p_detalle =>
      jsonb_build_object(

        'organismo_anterior',
          old.organismo,

        'organismo_nuevo',
          new.organismo,

        'impuesto_anterior',
          old.impuesto,

        'impuesto_nuevo',
          new.impuesto,

        'jurisdiccion_anterior',
          old.jurisdiccion,

        'jurisdiccion_nueva',
          new.jurisdiccion,

        'tipo_agente_anterior',
          old.tipo_agente,

        'tipo_agente_nuevo',
          new.tipo_agente,

        'regimen_codigo_anterior',
          old.regimen_codigo,

        'regimen_codigo_nuevo',
          new.regimen_codigo,

        'regimen_descripcion_anterior',
          old.regimen_descripcion,

        'regimen_descripcion_nueva',
          new.regimen_descripcion,

        'numero_inscripcion_anterior',
          old.numero_inscripcion_agente,

        'numero_inscripcion_nueva',
          new.numero_inscripcion_agente,

        'vigencia_desde_anterior',
          old.vigencia_desde,

        'vigencia_desde_nueva',
          new.vigencia_desde,

        'vigencia_hasta_anterior',
          old.vigencia_hasta,

        'vigencia_hasta_nueva',
          new.vigencia_hasta,

        'modo_alicuota_anterior',
          old.modo_alicuota,

        'modo_alicuota_nuevo',
          new.modo_alicuota,

        'alicuota_fija_anterior',
          old.alicuota_fija,

        'alicuota_fija_nueva',
          new.alicuota_fija,

        'requiere_certificado_anterior',
          old.requiere_certificado,

        'requiere_certificado_nuevo',
          new.requiere_certificado,

        'sistema_presentacion_anterior',
          old.sistema_presentacion,

        'sistema_presentacion_nuevo',
          new.sistema_presentacion,

        'activo_anterior',
          old.activo,

        'activo_nuevo',
          new.activo

      ),

    p_realizado_por =>
      v_actor

  );


  return new;

end;
$function$;


-- ============================================================
-- 6. FUNCIÓN INTERNA
-- ============================================================

revoke all on function
public.__drito_auditar_configuracion_agente_fiscal()
from public, anon, authenticated;


-- ============================================================
-- 7. TRIGGER OPERACIONAL
-- ============================================================

drop trigger if exists
configuraciones_agentes_fiscales_auditoria_operacional
on public.configuraciones_agentes_fiscales;


create trigger
configuraciones_agentes_fiscales_auditoria_operacional
after insert or update
on public.configuraciones_agentes_fiscales
for each row
execute function
public.__drito_auditar_configuracion_agente_fiscal();


-- ============================================================
-- 8. RECARGA POSTGREST
-- ============================================================

notify pgrst, 'reload schema';


-- ============================================================
-- 9. VERIFICACIÓN ESTRUCTURAL
-- ============================================================

select jsonb_build_object(

  'tabla_configuraciones_agentes',
    to_regclass(
      'public.configuraciones_agentes_fiscales'
    ) is not null,

  'helper_auditoria_existe',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'funcion_auditoria_existe',
    to_regprocedure(
      'public.__drito_auditar_configuracion_agente_fiscal()'
    ) is not null,

  'trigger_operacional_instalado',
    exists (
      select 1
      from pg_trigger tg
      where tg.tgrelid =
        'public.configuraciones_agentes_fiscales'::regclass

        and tg.tgname =
          'configuraciones_agentes_fiscales_auditoria_operacional'

        and not tg.tgisinternal
    ),

  'guardar_configuracion_existe',
    to_regprocedure(
      'public.guardar_configuracion_agente_fiscal(uuid,text,text,text,text,text,date,text,uuid,text,text,date,numeric,boolean,text,boolean,text)'
    ) is not null,

  'desactivar_configuracion_existe',
    to_regprocedure(
      'public.desactivar_configuracion_agente_fiscal(uuid,uuid)'
    ) is not null,

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a7_2;