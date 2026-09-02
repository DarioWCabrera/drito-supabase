-- ============================================================
-- DRITO
-- 16A — LIMPIEZA TEST UI SOLICITUDES WEB
--
-- Elimina exclusivamente:
-- - SOL-000001 de prueba
-- - sus ítems
-- - COT-000006 generada por esa SOL
-- - sus ítems
-- - auditorías ligadas a ambas entidades
--
-- Restablece:
-- - contador SOL = 0
-- - contador COT = 5
--
-- Tiene validaciones previas.
-- Si algo no coincide EXACTAMENTE con el test esperado,
-- aborta todo sin modificar datos.
-- ============================================================

begin;


do $$

declare

  v_sol_id constant uuid :=
    'c4f6b6b9-fd35-4c67-a408-d516fa5c6ae5';

  v_cot_id constant uuid :=
    '682b4ab0-0be0-41df-9a4f-b03ec1813221';

  v_comercio_id uuid;

  v_estado_sol text;
  v_numero_sol bigint;
  v_nombre_contacto text;
  v_cotizacion_vinculada uuid;

  v_estado_cot text;
  v_numero_cot bigint;
  v_total_cot numeric;

  v_contador_sol bigint;
  v_contador_cot bigint;

  v_cantidad_sol_comercio bigint;
  v_cotizaciones_posteriores bigint;

  v_canal_habilitado boolean;

begin

  -- ==========================================================
  -- 1. VALIDAR SOL EXACTA
  -- ==========================================================

  select
    sw.comercio_id,
    sw.estado,
    sw.numero,
    sw.nombre_contacto,
    sw.cotizacion_id

  into
    v_comercio_id,
    v_estado_sol,
    v_numero_sol,
    v_nombre_contacto,
    v_cotizacion_vinculada

  from public.solicitudes_web sw

  where sw.id = v_sol_id;


  if not found then
    raise exception
      'ABORTADO: no existe la SOL de prueba esperada';
  end if;


  if v_numero_sol <> 1 then
    raise exception
      'ABORTADO: la solicitud ya no es SOL-000001';
  end if;


  if v_estado_sol <> 'convertida' then
    raise exception
      'ABORTADO: la SOL no está en estado convertida';
  end if;


  if v_nombre_contacto <> 'Cliente prueba UI' then
    raise exception
      'ABORTADO: la SOL no corresponde al test UI';
  end if;


  if v_cotizacion_vinculada <> v_cot_id then
    raise exception
      'ABORTADO: la SOL ya no está vinculada a la COT de prueba esperada';
  end if;


  -- ==========================================================
  -- 2. ASEGURAR QUE NO EXISTEN OTRAS SOL REALES
  -- ==========================================================

  select count(*)
  into v_cantidad_sol_comercio

  from public.solicitudes_web sw

  where sw.comercio_id = v_comercio_id;


  if v_cantidad_sol_comercio <> 1 then
    raise exception
      'ABORTADO: existen otras solicitudes web en el comercio';
  end if;


  -- ==========================================================
  -- 3. VALIDAR COT EXACTA
  -- ==========================================================

  select
    c.estado,
    c.numero,
    c.total

  into
    v_estado_cot,
    v_numero_cot,
    v_total_cot

  from public.cotizaciones c

  where c.id = v_cot_id
    and c.comercio_id = v_comercio_id;


  if not found then
    raise exception
      'ABORTADO: no existe la COT de prueba esperada';
  end if;


  if v_numero_cot <> 6 then
    raise exception
      'ABORTADO: la cotización ya no es COT-000006';
  end if;


  if v_estado_cot <> 'borrador' then
    raise exception
      'ABORTADO: COT-000006 ya no está en borrador';
  end if;


  if v_total_cot <> 157300 then
    raise exception
      'ABORTADO: el total de COT-000006 ya no coincide con el test';
  end if;


  -- ==========================================================
  -- 4. NO PUEDE HABER COTIZACIONES POSTERIORES
  --
  -- Esto evita retroceder el contador si alguien creó
  -- COT-000007 o superiores mientras hacíamos la prueba.
  -- ==========================================================

  select count(*)
  into v_cotizaciones_posteriores

  from public.cotizaciones c

  where c.comercio_id = v_comercio_id
    and c.numero > 6;


  if v_cotizaciones_posteriores <> 0 then
    raise exception
      'ABORTADO: existen cotizaciones posteriores a COT-000006';
  end if;


  -- ==========================================================
  -- 5. VALIDAR CONTADORES
  -- ==========================================================

  select sc.ultimo_numero
  into v_contador_sol

  from public.solicitud_web_contadores sc

  where sc.comercio_id = v_comercio_id;


  if v_contador_sol <> 1 then
    raise exception
      'ABORTADO: el contador SOL ya no está en 1';
  end if;


  select cc.ultimo_numero
  into v_contador_cot

  from public.cotizacion_contadores cc

  where cc.comercio_id = v_comercio_id;


  if v_contador_cot <> 6 then
    raise exception
      'ABORTADO: el contador COT ya no está en 6';
  end if;


  -- ==========================================================
  -- 6. CANAL PÚBLICO DEBE SEGUIR APAGADO
  -- ==========================================================

  select csw.habilitado
  into v_canal_habilitado

  from public.configuraciones_solicitudes_web csw

  where csw.comercio_id = v_comercio_id;


  if v_canal_habilitado is distinct from false then
    raise exception
      'ABORTADO: el canal público está habilitado';
  end if;


  -- ==========================================================
  -- 7. LIMPIAR AUDITORÍAS DEL TEST
  -- ==========================================================

  delete from public.auditoria_operaciones ao

  where ao.comercio_id = v_comercio_id

    and ao.entidad_id in (
      v_sol_id::text,
      v_cot_id::text
    );


  -- ==========================================================
  -- 8. ELIMINAR ÍTEMS SOL
  -- ==========================================================

  delete from public.items_solicitud_web

  where solicitud_id = v_sol_id
    and comercio_id = v_comercio_id;


  -- ==========================================================
  -- 9. ELIMINAR SOL
  -- ==========================================================

  delete from public.solicitudes_web

  where id = v_sol_id
    and comercio_id = v_comercio_id;


  -- ==========================================================
  -- 10. ELIMINAR ÍTEMS COT
  -- ==========================================================

  delete from public.items_cotizacion

  where cotizacion_id = v_cot_id
    and comercio_id = v_comercio_id;


  -- ==========================================================
  -- 11. ELIMINAR COT DE PRUEBA
  -- ==========================================================

  delete from public.cotizaciones

  where id = v_cot_id
    and comercio_id = v_comercio_id
    and numero = 6
    and estado = 'borrador';


  -- ==========================================================
  -- 12. RESTABLECER CONTADOR SOL
  -- ==========================================================

  update public.solicitud_web_contadores

  set
    ultimo_numero = 0,
    updated_at = now()

  where comercio_id = v_comercio_id;


  -- ==========================================================
  -- 13. RESTABLECER CONTADOR COT
  -- ==========================================================

  update public.cotizacion_contadores

  set
    ultimo_numero = 5,
    updated_at = now()

  where comercio_id = v_comercio_id;

end;

$$;


commit;


-- ============================================================
-- 14. VERIFICACIÓN FINAL
-- ============================================================

select jsonb_build_object(

  'solicitudes_restantes',
    (
      select count(*)
      from public.solicitudes_web
    ),

  'items_sol_restantes',
    (
      select count(*)
      from public.items_solicitud_web
    ),

  'cot_000006_existe',
    exists (
      select 1
      from public.cotizaciones
      where id =
        '682b4ab0-0be0-41df-9a4f-b03ec1813221'
    ),

  'items_cot_test_restantes',
    (
      select count(*)
      from public.items_cotizacion
      where cotizacion_id =
        '682b4ab0-0be0-41df-9a4f-b03ec1813221'
    ),

  'auditorias_test_restantes',
    (
      select count(*)

      from public.auditoria_operaciones

      where entidad_id in (
        'c4f6b6b9-fd35-4c67-a408-d516fa5c6ae5',
        '682b4ab0-0be0-41df-9a4f-b03ec1813221'
      )
    ),

  'contador_sol',
    (
      select ultimo_numero

      from public.solicitud_web_contadores

      where comercio_id =
        '60840da6-f45a-44e0-9dca-6d42cc705604'
    ),

  'contador_cot',
    (
      select ultimo_numero

      from public.cotizacion_contadores

      where comercio_id =
        '60840da6-f45a-44e0-9dca-6d42cc705604'
    ),

  'canal_publico_habilitado',
    exists (
      select 1

      from public.configuraciones_solicitudes_web

      where comercio_id =
        '60840da6-f45a-44e0-9dca-6d42cc705604'

        and habilitado = true
    )

) as limpieza_16a_resultado;