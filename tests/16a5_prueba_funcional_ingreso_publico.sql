begin;

-- ============================================================
-- DRITO
-- 16A.5 — PRUEBA FUNCIONAL PUERTA PÚBLICA SOL
--
-- TODO TERMINA EN ROLLBACK
-- ============================================================


-- ============================================================
-- 1. CONTEXTO REAL
-- ============================================================

create temp table _test_16a5_ctx
on commit drop
as

select

  uc.usuario_id,

  uc.comercio_id,

  csw.canal_publico
    as canal_original,

  p.id
    as producto_id,

  p.nombre
    as producto_nombre,

  p.precio_venta
    as producto_precio,

  p.iva_porcentaje
    as producto_iva,

  p.moneda
    as producto_moneda,

  gen_random_uuid()
    as clave_idempotencia,

  coalesce(
    (
      select sc.ultimo_numero

      from public.solicitud_web_contadores sc

      where sc.comercio_id =
        uc.comercio_id
    ),
    0
  )
    as contador_sol_antes,

  coalesce(
    (
      select max(ao.id)

      from public.auditoria_operaciones ao
    ),
    0
  )
    as auditoria_id_antes

from public.usuarios_comercios uc

join public.configuraciones_solicitudes_web csw
  on csw.comercio_id =
     uc.comercio_id

join lateral (

  select pr.*

  from public.productos pr

  where pr.comercio_id =
        uc.comercio_id

    and pr.activo = true

    and pr.precio_venta
        is not null

    and pr.iva_porcentaje
        is not null

    and pr.moneda
        is not null

  order by pr.created_at

  limit 1

) p
  on true

where uc.activo = true
  and uc.rol = 'admin'

order by uc.created_at

limit 1;


do $$

begin

  if not exists (
    select 1
    from _test_16a5_ctx
  ) then

    raise exception
      'No se encontró contexto válido para ejecutar la prueba';

  end if;


  if exists (
    select 1

    from public.configuraciones_solicitudes_web csw

    join _test_16a5_ctx ctx
      on ctx.comercio_id =
         csw.comercio_id

    where csw.habilitado = true
  ) then

    raise exception
      'La prueba requiere que el canal comience apagado';

  end if;

end;

$$;


-- ============================================================
-- 2. TABLAS TEMPORALES DE RESULTADO
-- ============================================================

create temp table _test_16a5_bloqueo_inicial (

  bloqueo_correcto boolean,

  mensaje text

)
on commit drop;


create temp table _test_16a5_bloqueo_regenerar (

  bloqueo_correcto boolean,

  mensaje text

)
on commit drop;


create temp table _test_16a5_bloqueo_final (

  bloqueo_correcto boolean,

  mensaje text

)
on commit drop;


create temp table _test_16a5_publica (

  intento integer,

  solicitud_id uuid,

  numero bigint,

  referencia text,

  reutilizada boolean

)
on commit drop;


create temp table _test_16a5_actor (

  rol text

)
on commit drop;


-- anon necesita únicamente escribir en las temporales
-- utilizadas para verificar la llamada real.

grant select
on _test_16a5_ctx
to anon;


grant select, insert
on _test_16a5_publica
to anon;


grant select, insert
on _test_16a5_actor
to anon;



-- ============================================================
-- 3. CANAL APAGADO
--
-- La puerta pública debe rechazar la solicitud.
-- ============================================================

do $$

declare

  v_ctx record;

begin

  select *
  into v_ctx

  from _test_16a5_ctx;


  begin

    perform *

    from public.crear_solicitud_web_publica(

      v_ctx.canal_original,

      v_ctx.clave_idempotencia,

      'catalogo',

      'Cliente público test 16A.5',

      'Empresa pública test',

      '2983222222',

      'publico16a5@test.local',

      null,

      'Prueba pública controlada',

      'https://test.local/catalogo',

      jsonb_build_array(

        jsonb_build_object(

          'producto_id',
            v_ctx.producto_id,

          'cantidad',
            2

        )

      )

    );


    insert into _test_16a5_bloqueo_inicial

    values (
      false,
      'La solicitud fue permitida con el canal apagado'
    );


  exception
    when others then

      insert into _test_16a5_bloqueo_inicial

      values (
        sqlerrm =
          'Canal de solicitudes no disponible',

        sqlerrm
      );

  end;

end;

$$;



-- ============================================================
-- 4. JWT DEL ADMIN
-- ============================================================

select set_config(

  'request.jwt.claim.sub',

  usuario_id::text,

  true

)
from _test_16a5_ctx;


select set_config(

  'request.jwt.claim.role',

  'authenticated',

  true

)
from _test_16a5_ctx;


select set_config(

  'request.jwt.claims',

  jsonb_build_object(

    'sub',
      usuario_id::text,

    'role',
      'authenticated'

  )::text,

  true

)
from _test_16a5_ctx;



-- ============================================================
-- 5. HABILITAR MEDIANTE RPC AUTORIZADA
-- ============================================================

create temp table _test_16a5_habilitacion
on commit drop
as

select

  public.habilitar_solicitudes_web(
    ctx.comercio_id
  )
    as resultado

from _test_16a5_ctx ctx;



-- ============================================================
-- 6. REGENERAR MIENTRAS ESTÁ HABILITADO
--
-- DEBE BLOQUEARSE.
-- ============================================================

do $$

declare

  v_comercio uuid;

begin

  select comercio_id
  into v_comercio

  from _test_16a5_ctx;


  begin

    perform
      public.regenerar_canal_solicitudes_web(
        v_comercio
      );


    insert into _test_16a5_bloqueo_regenerar

    values (
      false,
      'La regeneración fue permitida con el canal habilitado'
    );


  exception
    when others then

      insert into _test_16a5_bloqueo_regenerar

      values (

        sqlerrm =
          'Deshabilitá el canal antes de regenerarlo',

        sqlerrm

      );

  end;

end;

$$;



-- ============================================================
-- 7. LLAMADA REAL COMO ANON
-- ============================================================

set local role anon;


insert into _test_16a5_actor (
  rol
)
values (
  current_user
);


insert into _test_16a5_publica (

  intento,

  solicitud_id,

  numero,

  referencia,

  reutilizada

)

select

  1,

  r.solicitud_id,

  r.numero,

  r.referencia,

  r.reutilizada

from _test_16a5_ctx ctx

cross join lateral

public.crear_solicitud_web_publica(

  ctx.canal_original,

  ctx.clave_idempotencia,

  'catalogo',

  'Cliente público test 16A.5',

  'Empresa pública test',

  '2983222222',

  'publico16a5@test.local',

  null,

  'Prueba pública controlada',

  'https://test.local/catalogo',

  jsonb_build_array(

    jsonb_build_object(

      'producto_id',
        ctx.producto_id,

      'cantidad',
        2

    )

  )

) r;



-- ============================================================
-- 8. SEGUNDA LLAMADA IDÉNTICA COMO ANON
--
-- Debe reutilizar la SOL.
-- ============================================================

insert into _test_16a5_publica (

  intento,

  solicitud_id,

  numero,

  referencia,

  reutilizada

)

select

  2,

  r.solicitud_id,

  r.numero,

  r.referencia,

  r.reutilizada

from _test_16a5_ctx ctx

cross join lateral

public.crear_solicitud_web_publica(

  ctx.canal_original,

  ctx.clave_idempotencia,

  'catalogo',

  'Cliente público test 16A.5',

  'Empresa pública test',

  '2983222222',

  'publico16a5@test.local',

  null,

  'Prueba pública controlada',

  'https://test.local/catalogo',

  jsonb_build_array(

    jsonb_build_object(

      'producto_id',
        ctx.producto_id,

      'cantidad',
        2

    )

  )

) r;


reset role;



-- ============================================================
-- 9. DESHABILITAR NUEVAMENTE
-- ============================================================

do $$

declare

  v_comercio uuid;

begin

  select comercio_id
  into v_comercio

  from _test_16a5_ctx;


  perform
    public.deshabilitar_solicitudes_web(
      v_comercio
    );

end;

$$;



-- ============================================================
-- 10. REGENERAR CANAL APAGADO
-- ============================================================

create temp table _test_16a5_regeneracion
on commit drop
as

select

  public.regenerar_canal_solicitudes_web(
    ctx.comercio_id
  )
    as resultado

from _test_16a5_ctx ctx;



-- ============================================================
-- 11. EL CANAL ORIGINAL YA NO DEBE SERVIR
-- ============================================================

do $$

declare

  v_ctx record;

begin

  select *
  into v_ctx

  from _test_16a5_ctx;


  begin

    perform *

    from public.crear_solicitud_web_publica(

      v_ctx.canal_original,

      gen_random_uuid(),

      'web',

      'Cliente bloqueo final',

      null,

      '2983333333',

      null,

      null,

      null,

      'https://test.local',

      jsonb_build_array(

        jsonb_build_object(

          'producto_id',
            v_ctx.producto_id,

          'cantidad',
            1

        )

      )

    );


    insert into _test_16a5_bloqueo_final

    values (
      false,
      'El canal anterior continuó aceptando solicitudes'
    );


  exception
    when others then

      insert into _test_16a5_bloqueo_final

      values (

        sqlerrm =
          'Canal de solicitudes no disponible',

        sqlerrm

      );

  end;

end;

$$;



-- ============================================================
-- 12. VERIFICACIÓN INTEGRAL
-- ============================================================

select jsonb_build_object(

  -- ----------------------------------------------------------
  -- CANAL APAGADO
  -- ----------------------------------------------------------

  'canal_apagado_bloquea',
    (
      select bloqueo_correcto
      from _test_16a5_bloqueo_inicial
    ),

  'mensaje_canal_apagado',
    (
      select mensaje
      from _test_16a5_bloqueo_inicial
    ),


  -- ----------------------------------------------------------
  -- HABILITACIÓN
  -- ----------------------------------------------------------

  'habilitacion_correcta',
    (
      select
        (resultado->>'habilitado')::boolean

      from _test_16a5_habilitacion
    ),

  'canal_habilitado_durante_prueba',
    (
      select csw.habilitado

      from public.configuraciones_solicitudes_web csw

      cross join _test_16a5_ctx ctx

      where csw.comercio_id =
        ctx.comercio_id
    ) = false,

  -- El valor anterior es false porque a esta altura
  -- del test ya fue deshabilitado nuevamente.


  -- ----------------------------------------------------------
  -- REGENERACIÓN BLOQUEADA ENCENDIDO
  -- ----------------------------------------------------------

  'regeneracion_habilitado_bloqueada',
    (
      select bloqueo_correcto
      from _test_16a5_bloqueo_regenerar
    ),

  'mensaje_regeneracion_habilitado',
    (
      select mensaje
      from _test_16a5_bloqueo_regenerar
    ),


  -- ----------------------------------------------------------
  -- LLAMADA REAL ANON
  -- ----------------------------------------------------------

  'rol_llamada_publica',
    (
      select rol
      from _test_16a5_actor
    ),

  'anon_real',
    (
      select rol = 'anon'
      from _test_16a5_actor
    ),


  -- ----------------------------------------------------------
  -- IDEMPOTENCIA
  -- ----------------------------------------------------------

  'primera_reutilizada',
    (
      select reutilizada

      from _test_16a5_publica

      where intento = 1
    ),

  'segunda_reutilizada',
    (
      select reutilizada

      from _test_16a5_publica

      where intento = 2
    ),

  'mismo_solicitud_id',
    (
      select
        count(
          distinct solicitud_id
        ) = 1

      from _test_16a5_publica
    ),

  'mismo_numero',
    (
      select
        count(
          distinct numero
        ) = 1

      from _test_16a5_publica
    ),

  'referencia',
    (
      select referencia

      from _test_16a5_publica

      where intento = 1
    ),


  -- ----------------------------------------------------------
  -- SOL CREADA
  -- ----------------------------------------------------------

  'solicitudes_creadas',
    (
      select count(*)

      from public.solicitudes_web sw

      cross join _test_16a5_ctx ctx

      where sw.comercio_id =
        ctx.comercio_id
    ),

  'estado_solicitud',
    (
      select sw.estado

      from public.solicitudes_web sw

      join _test_16a5_publica p
        on p.solicitud_id =
           sw.id

      where p.intento = 1
    ),

  'items_creados',
    (
      select count(*)

      from public.items_solicitud_web i

      join _test_16a5_publica p
        on p.solicitud_id =
           i.solicitud_id

      where p.intento = 1
    ),

  'snapshot_nombre_correcto',
    (
      select
        i.nombre_snapshot =
          ctx.producto_nombre

      from public.items_solicitud_web i

      join _test_16a5_publica p
        on p.solicitud_id =
           i.solicitud_id

      cross join _test_16a5_ctx ctx

      where p.intento = 1

      limit 1
    ),

  'snapshot_precio_correcto',
    (
      select
        i.precio_referencia =
          ctx.producto_precio

      from public.items_solicitud_web i

      join _test_16a5_publica p
        on p.solicitud_id =
           i.solicitud_id

      cross join _test_16a5_ctx ctx

      where p.intento = 1

      limit 1
    ),


  -- ----------------------------------------------------------
  -- CONTADOR
  -- ----------------------------------------------------------

  'contador_incrementado_una_vez',
    (
      select
        sc.ultimo_numero =
          ctx.contador_sol_antes + 1

      from public.solicitud_web_contadores sc

      cross join _test_16a5_ctx ctx

      where sc.comercio_id =
        ctx.comercio_id
    ),


  -- ----------------------------------------------------------
  -- APAGADO + REGENERACIÓN
  -- ----------------------------------------------------------

  'canal_final_apagado',
    (
      select
        csw.habilitado = false

      from public.configuraciones_solicitudes_web csw

      cross join _test_16a5_ctx ctx

      where csw.comercio_id =
        ctx.comercio_id
    ),

  'canal_regenerado',
    (
      select
        (
          resultado->>'canal_publico'
        )::uuid
        <>
        ctx.canal_original

      from _test_16a5_regeneracion

      cross join _test_16a5_ctx ctx
    ),

  'canal_original_bloqueado',
    (
      select bloqueo_correcto
      from _test_16a5_bloqueo_final
    ),

  'mensaje_canal_original',
    (
      select mensaje
      from _test_16a5_bloqueo_final
    ),


  -- ----------------------------------------------------------
  -- AUDITORÍA
  -- ----------------------------------------------------------

  'auditoria_habilitacion',
    (
      select count(*)

      from public.auditoria_operaciones ao

      cross join _test_16a5_ctx ctx

      where ao.id >
            ctx.auditoria_id_antes

        and ao.comercio_id =
            ctx.comercio_id

        and ao.modulo =
            'solicitudes_web'

        and ao.accion =
            'solicitudes_web_habilitadas'
    ),

  'auditoria_recepcion',
    (
      select count(*)

      from public.auditoria_operaciones ao

      cross join _test_16a5_ctx ctx

      where ao.id >
            ctx.auditoria_id_antes

        and ao.comercio_id =
            ctx.comercio_id

        and ao.modulo =
            'solicitudes_web'

        and ao.accion =
            'solicitud_web_recibida'
    ),

  'auditoria_deshabilitacion',
    (
      select count(*)

      from public.auditoria_operaciones ao

      cross join _test_16a5_ctx ctx

      where ao.id >
            ctx.auditoria_id_antes

        and ao.comercio_id =
            ctx.comercio_id

        and ao.modulo =
            'solicitudes_web'

        and ao.accion =
            'solicitudes_web_deshabilitadas'
    ),

  'auditoria_regeneracion',
    (
      select count(*)

      from public.auditoria_operaciones ao

      cross join _test_16a5_ctx ctx

      where ao.id >
            ctx.auditoria_id_antes

        and ao.comercio_id =
            ctx.comercio_id

        and ao.modulo =
            'solicitudes_web'

        and ao.accion =
            'canal_solicitudes_web_regenerado'
    )

) as prueba_funcional_16a5;


rollback;