-- ============================================================
-- DRITO
-- TEST UI 16A.4.2
-- CREA UNA SOL DE PRUEBA PARA VALIDAR LA BANDEJA DESDE FRONTEND
--
-- IMPORTANTE:
-- - habilita el canal solo durante esta operación;
-- - al terminar vuelve a dejarlo apagado;
-- - crea UNA solicitud persistente de prueba;
-- - no activa recepción pública.
-- ============================================================

do $$

declare

  v_usuario_id uuid;
  v_comercio_id uuid;
  v_producto_id uuid;

  v_clave_idempotencia uuid :=
    gen_random_uuid();

begin

  -- ----------------------------------------------------------
  -- 1. CONTEXTO REAL
  -- ----------------------------------------------------------

  select
    uc.usuario_id,
    uc.comercio_id

  into
    v_usuario_id,
    v_comercio_id

  from public.usuarios_comercios uc

  where uc.activo = true
    and uc.rol = 'admin'

  order by uc.created_at

  limit 1;


  if v_usuario_id is null
     or v_comercio_id is null
  then

    raise exception
      'No se encontró un administrador activo';

  end if;


  select p.id
  into v_producto_id

  from public.productos p

  where p.comercio_id = v_comercio_id
    and p.activo = true
    and p.precio_venta is not null
    and p.iva_porcentaje is not null
    and p.moneda is not null

  order by p.created_at

  limit 1;


  if v_producto_id is null then

    raise exception
      'No se encontró un producto activo válido';

  end if;


  -- ----------------------------------------------------------
  -- 2. HABILITAR TEMPORALMENTE
  -- ----------------------------------------------------------

  update public.configuraciones_solicitudes_web

  set
    habilitado = true,
    habilitado_at = now(),
    habilitado_por = v_usuario_id

  where comercio_id = v_comercio_id;


  -- ----------------------------------------------------------
  -- 3. CREAR SOL
  -- ----------------------------------------------------------

  perform *

  from public.__drito_crear_solicitud_web(

    v_comercio_id,

    v_clave_idempotencia,

    'catalogo',

    'Cliente prueba UI',

    'Empresa prueba UI',

    '2983111111',

    'prueba-ui@drito.local',

    null,

    'Solicitud creada para validar la bandeja de Drito.',

    'https://test.local/solicitudes-ui',

    jsonb_build_array(

      jsonb_build_object(

        'producto_id',
          v_producto_id,

        'cantidad',
          2

      )

    )

  );


  -- ----------------------------------------------------------
  -- 4. VOLVER A APAGAR EL CANAL
  -- ----------------------------------------------------------

  update public.configuraciones_solicitudes_web

  set
    habilitado = false,
    habilitado_at = null,
    habilitado_por = null

  where comercio_id = v_comercio_id;

end;

$$;


-- ============================================================
-- VERIFICACIÓN
-- ============================================================

select jsonb_build_object(

  'canal_publico_habilitado',
    exists (
      select 1
      from public.configuraciones_solicitudes_web
      where habilitado = true
    ),

  'solicitud_prueba',
    (

      select jsonb_build_object(

        'id',
          sw.id,

        'referencia',
          'SOL-' ||
          lpad(
            sw.numero::text,
            6,
            '0'
          ),

        'estado',
          sw.estado,

        'nombre_contacto',
          sw.nombre_contacto,

        'created_at',
          sw.created_at

      )

      from public.solicitudes_web sw

      where sw.nombre_contacto =
        'Cliente prueba UI'

      order by sw.created_at desc

      limit 1

    )

) as prueba_ui_16a4_2;