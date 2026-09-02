-- ============================================================
-- DRITO
-- PASO 16A.2
-- MOTOR INTERNO + GESTIÓN DE SOLICITUDES WEB
--
-- Esta migración:
-- - genera numeración SOL por comercio;
-- - implementa idempotencia;
-- - crea solicitudes e ítems mediante motor INTERNO;
-- - permite revisar/descartar solicitudes desde Drito;
-- - permite DESHABILITAR el canal;
-- - registra auditoría operacional.
--
-- IMPORTANTE:
-- - NO existe todavía RPC pública de recepción web.
-- - anon NO puede crear solicitudes.
-- - authenticated NO puede invocar el motor de alta.
-- - NO se crea todavía una RPC para HABILITAR el canal.
-- ============================================================


-- ============================================================
-- 1. HASH DE IDEMPOTENCIA
-- ============================================================

alter table public.solicitudes_web
add column if not exists solicitud_hash text null;


do $$
begin

  if not exists (
    select 1
    from pg_constraint
    where conname = 'solicitudes_web_hash_check'
      and conrelid = 'public.solicitudes_web'::regclass
  ) then

    alter table public.solicitudes_web
    add constraint solicitudes_web_hash_check
    check (
      solicitud_hash is null
      or length(solicitud_hash) = 32
    );

  end if;

end;
$$;


-- ============================================================
-- 2. GENERADOR INTERNO DE NUMERACIÓN SOL
-- ============================================================

create or replace function
public.__drito_siguiente_numero_solicitud_web(
  p_comercio_id uuid
)
returns bigint

language plpgsql
security definer
set search_path = public

as $$

declare

  v_numero bigint;

begin

  if p_comercio_id is null then
    raise exception
      'El comercio es obligatorio';
  end if;


  if not exists (
    select 1
    from public.comercios
    where id = p_comercio_id
  ) then
    raise exception
      'El comercio indicado no existe';
  end if;


  insert into public.solicitud_web_contadores (
    comercio_id,
    ultimo_numero,
    updated_at
  )
  values (
    p_comercio_id,
    1,
    now()
  )

  on conflict (comercio_id)

  do update set
    ultimo_numero =
      public.solicitud_web_contadores.ultimo_numero + 1,
    updated_at = now()

  returning ultimo_numero
  into v_numero;


  return v_numero;

end;

$$;


revoke all on function
public.__drito_siguiente_numero_solicitud_web(uuid)
from public, anon, authenticated;


-- ============================================================
-- 3. MOTOR INTERNO DE ALTA
--
-- No es una RPC pública.
--
-- Más adelante el backend/canal web autorizado podrá delegar
-- en este motor.
--
-- Aun así, el propio motor exige:
-- configuraciones_solicitudes_web.habilitado = true.
-- ============================================================

create or replace function
public.__drito_crear_solicitud_web(

  p_comercio_id uuid,

  p_clave_idempotencia uuid,

  p_origen text,

  p_nombre_contacto text,

  p_empresa text,

  p_telefono text,

  p_email text,

  p_cuit_cuil text,

  p_mensaje text,

  p_origen_url text,

  p_items jsonb

)
returns table (

  solicitud_id uuid,

  numero bigint,

  referencia text,

  reutilizada boolean

)

language plpgsql
security definer
set search_path = public

as $$

declare

  v_habilitado boolean;

  v_hash text;

  v_existente public.solicitudes_web%rowtype;

  v_numero bigint;

  v_solicitud_id uuid;

  v_item jsonb;

  v_producto public.productos%rowtype;

  v_producto_id uuid;

  v_cantidad numeric;

  v_nombre text;

  v_codigo text;

  v_descripcion text;

  v_unidad text;

  v_precio numeric;

  v_moneda text;

  v_items_count integer := 0;

begin

  -- ----------------------------------------------------------
  -- Validaciones básicas
  -- ----------------------------------------------------------

  if p_comercio_id is null then
    raise exception
      'El comercio es obligatorio';
  end if;


  if p_clave_idempotencia is null then
    raise exception
      'La clave de idempotencia es obligatoria';
  end if;


  if nullif(trim(coalesce(p_nombre_contacto, '')), '')
     is null then
    raise exception
      'El nombre de contacto es obligatorio';
  end if;


  if length(trim(p_nombre_contacto)) < 2 then
    raise exception
      'El nombre de contacto debe tener al menos 2 caracteres';
  end if;


  if
    nullif(trim(coalesce(p_telefono, '')), '') is null
    and
    nullif(trim(coalesce(p_email, '')), '') is null
  then

    raise exception
      'La solicitud debe incluir teléfono o email';

  end if;


  if p_items is null
     or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0
  then

    raise exception
      'La solicitud debe incluir al menos un ítem';

  end if;


  if coalesce(p_origen, 'web') not in (
    'web',
    'catalogo',
    'api',
    'manual'
  ) then

    raise exception
      'Origen de solicitud inválido';

  end if;


  -- ----------------------------------------------------------
  -- El canal DEBE estar habilitado
  -- ----------------------------------------------------------

  select csw.habilitado
  into v_habilitado

  from public.configuraciones_solicitudes_web csw

  where csw.comercio_id = p_comercio_id

  for share;


  if coalesce(v_habilitado, false) = false then

    raise exception
      'El canal de solicitudes web no está habilitado para este comercio';

  end if;


  -- ----------------------------------------------------------
  -- Hash de la intención
  --
  -- No es un hash de seguridad.
  -- Se usa para detectar reutilización incorrecta de una
  -- clave idempotente con otro contenido.
  -- ----------------------------------------------------------

  v_hash := md5(

    jsonb_build_object(

      'comercio_id',
        p_comercio_id,

      'origen',
        coalesce(p_origen, 'web'),

      'nombre_contacto',
        trim(p_nombre_contacto),

      'empresa',
        nullif(trim(coalesce(p_empresa, '')), ''),

      'telefono',
        nullif(trim(coalesce(p_telefono, '')), ''),

      'email',
        nullif(trim(coalesce(p_email, '')), ''),

      'cuit_cuil',
        nullif(trim(coalesce(p_cuit_cuil, '')), ''),

      'mensaje',
        nullif(trim(coalesce(p_mensaje, '')), ''),

      'origen_url',
        nullif(trim(coalesce(p_origen_url, '')), ''),

      'items',
        p_items

    )::text

  );


  -- ----------------------------------------------------------
  -- Idempotencia
  -- ----------------------------------------------------------

  select sw.*
  into v_existente

  from public.solicitudes_web sw

  where sw.comercio_id = p_comercio_id
    and sw.clave_idempotencia = p_clave_idempotencia;


  if found then

    if v_existente.solicitud_hash is distinct from v_hash then

      raise exception
        'La clave de idempotencia ya fue utilizada para otra solicitud';

    end if;


    return query

    select
      v_existente.id,
      v_existente.numero,
      'SOL-' || lpad(v_existente.numero::text, 6, '0'),
      true;


    return;

  end if;


  -- ----------------------------------------------------------
  -- Numeración
  -- ----------------------------------------------------------

  v_numero :=
    public.__drito_siguiente_numero_solicitud_web(
      p_comercio_id
    );


  -- ----------------------------------------------------------
  -- Cabecera
  -- ----------------------------------------------------------

  insert into public.solicitudes_web (

    comercio_id,

    numero,

    clave_idempotencia,

    solicitud_hash,

    estado,

    origen,

    nombre_contacto,

    empresa,

    telefono,

    email,

    cuit_cuil,

    mensaje,

    origen_url

  )
  values (

    p_comercio_id,

    v_numero,

    p_clave_idempotencia,

    v_hash,

    'recibida',

    coalesce(p_origen, 'web'),

    trim(p_nombre_contacto),

    nullif(trim(coalesce(p_empresa, '')), ''),

    nullif(trim(coalesce(p_telefono, '')), ''),

    nullif(trim(coalesce(p_email, '')), ''),

    nullif(trim(coalesce(p_cuit_cuil, '')), ''),

    nullif(trim(coalesce(p_mensaje, '')), ''),

    nullif(trim(coalesce(p_origen_url, '')), '')

  )

  returning id
  into v_solicitud_id;


  -- ----------------------------------------------------------
  -- Ítems
  -- ----------------------------------------------------------

  for v_item in

    select value
    from jsonb_array_elements(p_items)

  loop

    v_items_count := v_items_count + 1;


    v_producto_id :=
      nullif(
        v_item->>'producto_id',
        ''
      )::uuid;


    v_cantidad :=
      nullif(
        v_item->>'cantidad',
        ''
      )::numeric;


    if v_cantidad is null
       or v_cantidad <= 0
    then

      raise exception
        'La cantidad del ítem % debe ser mayor a cero',
        v_items_count;

    end if;


    -- --------------------------------------------------------
    -- Producto existente:
    -- snapshot tomado desde Drito, no desde el navegador.
    -- --------------------------------------------------------

    if v_producto_id is not null then

      select p.*
      into v_producto

      from public.productos p

      where p.id = v_producto_id
        and p.comercio_id = p_comercio_id;


      if not found then

        raise exception
          'El producto % no pertenece al comercio',
          v_producto_id;

      end if;


      v_codigo := v_producto.codigo;

      v_nombre := v_producto.nombre;

      v_descripcion := v_producto.descripcion;

      v_unidad := v_producto.unidad_medida;

      v_precio := v_producto.precio_venta;

      v_moneda := v_producto.moneda;


    else

      -- ------------------------------------------------------
      -- Ítem libre:
      -- puede existir en futuras integraciones sin producto.
      -- ------------------------------------------------------

      v_codigo :=
        nullif(
          trim(
            coalesce(
              v_item->>'codigo_snapshot',
              ''
            )
          ),
          ''
        );


      v_nombre :=
        nullif(
          trim(
            coalesce(
              v_item->>'nombre_snapshot',
              ''
            )
          ),
          ''
        );


      if v_nombre is null then

        raise exception
          'El ítem % debe indicar nombre_snapshot',
          v_items_count;

      end if;


      v_descripcion :=
        nullif(
          trim(
            coalesce(
              v_item->>'descripcion_snapshot',
              ''
            )
          ),
          ''
        );


      v_unidad :=
        nullif(
          trim(
            coalesce(
              v_item->>'unidad_medida_snapshot',
              ''
            )
          ),
          ''
        );


      v_precio :=
        nullif(
          v_item->>'precio_referencia',
          ''
        )::numeric;


      if v_precio is not null
         and v_precio < 0
      then

        raise exception
          'El precio de referencia del ítem % no puede ser negativo',
          v_items_count;

      end if;


      v_moneda :=
        nullif(
          trim(
            coalesce(
              v_item->>'moneda_snapshot',
              ''
            )
          ),
          ''
        );

    end if;


    insert into public.items_solicitud_web (

      solicitud_id,

      comercio_id,

      producto_id,

      cantidad,

      codigo_snapshot,

      nombre_snapshot,

      descripcion_snapshot,

      unidad_medida_snapshot,

      precio_referencia,

      moneda_snapshot,

      observaciones

    )
    values (

      v_solicitud_id,

      p_comercio_id,

      v_producto_id,

      v_cantidad,

      v_codigo,

      v_nombre,

      v_descripcion,

      v_unidad,

      v_precio,

      v_moneda,

      nullif(
        trim(
          coalesce(
            v_item->>'observaciones',
            ''
          )
        ),
        ''
      )

    );

  end loop;


  -- ----------------------------------------------------------
  -- Auditoría
  --
  -- No guardamos teléfono/email/CUIT en auditoría.
  -- La información personal queda solamente en la solicitud.
  -- ----------------------------------------------------------

  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id,

    'solicitudes_web',

    'solicitud_web_recibida',

    'solicitud_web',

    v_solicitud_id::text,

    'SOL-' || lpad(v_numero::text, 6, '0'),

    jsonb_build_object(

      'numero',
        v_numero,

      'origen',
        coalesce(p_origen, 'web'),

      'items',
        v_items_count

    ),

    auth.uid()

  );


  return query

  select
    v_solicitud_id,
    v_numero,
    'SOL-' || lpad(v_numero::text, 6, '0'),
    false;

end;

$$;


revoke all on function
public.__drito_crear_solicitud_web(
  uuid,
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  jsonb
)
from public, anon, authenticated;


-- ============================================================
-- 4. RPC INTERNA PARA GESTIÓN DESDE DRITO
--
-- Estados gestionables aquí:
--
-- recibida -> en_revision
-- recibida -> descartada
-- en_revision -> descartada
--
-- "convertida" NO se establece desde esta RPC.
-- Tendrá su propio motor transaccional al convertir a COT.
-- ============================================================

create or replace function
public.cambiar_estado_solicitud_web(

  p_solicitud_id uuid,

  p_estado text,

  p_motivo_descarte text default null

)
returns jsonb

language plpgsql
security definer
set search_path = public

as $$

declare

  v_solicitud public.solicitudes_web%rowtype;

  v_usuario uuid;

  v_estado_anterior text;

begin

  v_usuario := auth.uid();


  if v_usuario is null then
    raise exception
      'Usuario no autenticado';
  end if;


  select sw.*
  into v_solicitud

  from public.solicitudes_web sw

  where sw.id = p_solicitud_id

  for update;


  if not found then
    raise exception
      'Solicitud web no encontrada';
  end if;


  perform public.exigir_permiso_comercio(

    v_solicitud.comercio_id,

    'solicitudes_web.gestionar'

  );


  v_estado_anterior := v_solicitud.estado;


  if v_estado_anterior in (
    'convertida',
    'descartada'
  ) then

    raise exception
      'La solicitud ya se encuentra en estado %',
      v_estado_anterior;

  end if;


  if p_estado not in (
    'en_revision',
    'descartada'
  ) then

    raise exception
      'Estado de solicitud no permitido desde esta operación';

  end if;


  -- ----------------------------------------------------------
  -- EN REVISIÓN
  -- ----------------------------------------------------------

  if p_estado = 'en_revision' then

    update public.solicitudes_web
    set
      estado = 'en_revision',
      revisado_por = coalesce(
        revisado_por,
        v_usuario
      ),
      revisado_at = coalesce(
        revisado_at,
        now()
      )
    where id = p_solicitud_id;


    perform public.__drito_registrar_auditoria_operacion(

      v_solicitud.comercio_id,

      'solicitudes_web',

      'solicitud_web_en_revision',

      'solicitud_web',

      p_solicitud_id::text,

      'SOL-' ||
        lpad(
          v_solicitud.numero::text,
          6,
          '0'
        ),

      jsonb_build_object(
        'estado_anterior',
          v_estado_anterior,
        'estado_nuevo',
          'en_revision'
      ),

      v_usuario

    );

  end if;


  -- ----------------------------------------------------------
  -- DESCARTADA
  -- ----------------------------------------------------------

  if p_estado = 'descartada' then

    if length(
      trim(
        coalesce(
          p_motivo_descarte,
          ''
        )
      )
    ) < 3 then

      raise exception
        'El motivo de descarte debe tener al menos 3 caracteres';

    end if;


    update public.solicitudes_web
    set
      estado = 'descartada',
      descartado_por = v_usuario,
      descartado_at = now(),
      motivo_descarte =
        trim(p_motivo_descarte)
    where id = p_solicitud_id;


    perform public.__drito_registrar_auditoria_operacion(

      v_solicitud.comercio_id,

      'solicitudes_web',

      'solicitud_web_descartada',

      'solicitud_web',

      p_solicitud_id::text,

      'SOL-' ||
        lpad(
          v_solicitud.numero::text,
          6,
          '0'
        ),

      jsonb_build_object(
        'estado_anterior',
          v_estado_anterior,
        'estado_nuevo',
          'descartada',
        'motivo',
          trim(p_motivo_descarte)
      ),

      v_usuario

    );

  end if;


  return (

    select jsonb_build_object(

      'solicitud_id',
        sw.id,

      'numero',
        sw.numero,

      'referencia',
        'SOL-' ||
        lpad(
          sw.numero::text,
          6,
          '0'
        ),

      'estado',
        sw.estado,

      'revisado_at',
        sw.revisado_at,

      'descartado_at',
        sw.descartado_at,

      'motivo_descarte',
        sw.motivo_descarte

    )

    from public.solicitudes_web sw

    where sw.id = p_solicitud_id

  );

end;

$$;


revoke all on function
public.cambiar_estado_solicitud_web(
  uuid,
  text,
  text
)
from public, anon;


grant execute on function
public.cambiar_estado_solicitud_web(
  uuid,
  text,
  text
)
to authenticated;


-- ============================================================
-- 5. RPC PARA DESHABILITAR EL CANAL
--
-- Deliberadamente NO se crea todavía una función
-- para habilitarlo.
--
-- La activación real se hará más adelante, cuando Drito y
-- el backend público estén listos.
-- ============================================================

create or replace function
public.deshabilitar_solicitudes_web(
  p_comercio_id uuid
)
returns jsonb

language plpgsql
security definer
set search_path = public

as $$

declare

  v_usuario uuid;

  v_estaba_habilitado boolean;

begin

  v_usuario := auth.uid();


  if v_usuario is null then
    raise exception
      'Usuario no autenticado';
  end if;


  perform public.exigir_permiso_comercio(

    p_comercio_id,

    'solicitudes_web.configurar'

  );


  select habilitado
  into v_estaba_habilitado

  from public.configuraciones_solicitudes_web

  where comercio_id = p_comercio_id

  for update;


  if not found then

    raise exception
      'No existe configuración de solicitudes web para el comercio';

  end if;


  update public.configuraciones_solicitudes_web
  set
    habilitado = false,
    habilitado_at = null,
    habilitado_por = null
  where comercio_id = p_comercio_id;


  if coalesce(v_estaba_habilitado, false) = true then

    perform public.__drito_registrar_auditoria_operacion(

      p_comercio_id,

      'solicitudes_web',

      'solicitudes_web_deshabilitadas',

      'configuracion_solicitudes_web',

      p_comercio_id::text,

      null,

      jsonb_build_object(
        'habilitado_anterior',
          true,
        'habilitado_nuevo',
          false
      ),

      v_usuario

    );

  end if;


  return jsonb_build_object(
    'comercio_id',
      p_comercio_id,
    'habilitado',
      false
  );

end;

$$;


revoke all on function
public.deshabilitar_solicitudes_web(uuid)
from public, anon;


grant execute on function
public.deshabilitar_solicitudes_web(uuid)
to authenticated;


-- ============================================================
-- 6. POSTGREST
-- ============================================================

notify pgrst, 'reload schema';


-- ============================================================
-- 7. VERIFICACIÓN ESTRUCTURAL
-- ============================================================

select jsonb_build_object(

  'hash_instalado',
    exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'solicitudes_web'
        and column_name = 'solicitud_hash'
    ),

  'generador_sol_existe',
    to_regprocedure(
      'public.__drito_siguiente_numero_solicitud_web(uuid)'
    ) is not null,

  'motor_alta_existe',
    to_regprocedure(
      'public.__drito_crear_solicitud_web(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)'
    ) is not null,

  'rpc_estado_existe',
    to_regprocedure(
      'public.cambiar_estado_solicitud_web(uuid,text,text)'
    ) is not null,

  'rpc_deshabilitar_existe',
    to_regprocedure(
      'public.deshabilitar_solicitudes_web(uuid)'
    ) is not null,


  -- ----------------------------------------------------------
  -- MOTOR DE ALTA CERRADO
  -- ----------------------------------------------------------

  'anon_motor_alta',
    has_function_privilege(
      'anon',
      'public.__drito_crear_solicitud_web(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)',
      'EXECUTE'
    ),

  'authenticated_motor_alta',
    has_function_privilege(
      'authenticated',
      'public.__drito_crear_solicitud_web(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)',
      'EXECUTE'
    ),


  -- ----------------------------------------------------------
  -- GENERADOR INTERNO CERRADO
  -- ----------------------------------------------------------

  'anon_generador_sol',
    has_function_privilege(
      'anon',
      'public.__drito_siguiente_numero_solicitud_web(uuid)',
      'EXECUTE'
    ),

  'authenticated_generador_sol',
    has_function_privilege(
      'authenticated',
      'public.__drito_siguiente_numero_solicitud_web(uuid)',
      'EXECUTE'
    ),


  -- ----------------------------------------------------------
  -- GESTIÓN AUTENTICADA
  -- ----------------------------------------------------------

  'anon_rpc_estado',
    has_function_privilege(
      'anon',
      'public.cambiar_estado_solicitud_web(uuid,text,text)',
      'EXECUTE'
    ),

  'authenticated_rpc_estado',
    has_function_privilege(
      'authenticated',
      'public.cambiar_estado_solicitud_web(uuid,text,text)',
      'EXECUTE'
    ),

  'anon_rpc_deshabilitar',
    has_function_privilege(
      'anon',
      'public.deshabilitar_solicitudes_web(uuid)',
      'EXECUTE'
    ),

  'authenticated_rpc_deshabilitar',
    has_function_privilege(
      'authenticated',
      'public.deshabilitar_solicitudes_web(uuid)',
      'EXECUTE'
    ),


  -- ----------------------------------------------------------
  -- ESTADO ACTUAL
  -- ----------------------------------------------------------

  'configuraciones_habilitadas',
    (
      select count(*)
      from public.configuraciones_solicitudes_web
      where habilitado = true
    ),

  'solicitudes_actuales',
    (
      select count(*)
      from public.solicitudes_web
    ),

  'items_actuales',
    (
      select count(*)
      from public.items_solicitud_web
    )

) as verificacion_16a2;