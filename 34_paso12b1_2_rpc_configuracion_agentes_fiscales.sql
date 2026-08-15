-- ============================================================
-- DRITO
-- PASO 12B.1.2
-- RPC seguras para configuración de agentes fiscales
--
-- Requiere:
--   33_paso12b1_configuracion_agentes_fiscales.sql
--
-- Permiso utilizado:
--   facturacion.configurar
--
-- Objetivos:
-- - Consultar configuraciones fiscales del comercio.
-- - Crear configuraciones.
-- - Editar configuraciones existentes.
-- - Desactivar configuraciones sin borrarlas físicamente.
--
-- REGLAS:
-- - Sin acceso directo a la tabla desde frontend.
-- - Todas las operaciones validan comercio + permiso.
-- - No configura agentes automáticamente.
-- - No genera retenciones ni percepciones.
-- - No toca Caja.
-- - No toca ventas/compras/cuentas corrientes.
-- ============================================================


-- ============================================================
-- 1. LISTAR CONFIGURACIONES DEL COMERCIO
-- ============================================================

create or replace function
  public.listar_configuraciones_agentes_fiscales(
    p_comercio_id uuid
  )
returns setof public.configuraciones_agentes_fiscales
language plpgsql
security definer
set search_path = public, auth
as $$
begin

  if auth.uid() is null then
    raise exception 'Usuario no autenticado'
      using errcode = '42501';
  end if;

  if p_comercio_id is null then
    raise exception 'El comercio es obligatorio'
      using errcode = '22023';
  end if;

  perform public.exigir_permiso_comercio(
    p_comercio_id,
    'facturacion.configurar'
  );

  return query
  select c.*
  from public.configuraciones_agentes_fiscales c
  where c.comercio_id = p_comercio_id
  order by
    c.activo desc,
    c.impuesto,
    c.tipo_agente,
    c.jurisdiccion,
    c.vigencia_desde desc,
    c.created_at desc;

end;
$$;


-- ============================================================
-- 2. CREAR / EDITAR CONFIGURACIÓN
--
-- Si p_id es NULL:
--   crea una configuración nueva.
--
-- Si p_id tiene valor:
--   actualiza esa configuración.
-- ============================================================

create or replace function
  public.guardar_configuracion_agente_fiscal(

    p_comercio_id uuid,

    p_organismo text,

    p_impuesto text,

    p_jurisdiccion text,

    p_tipo_agente text,

    p_regimen_descripcion text,

    p_vigencia_desde date,

    p_modo_alicuota text,

    p_id uuid default null,

    p_regimen_codigo text default null,

    p_numero_inscripcion_agente text default null,

    p_vigencia_hasta date default null,

    p_alicuota_fija numeric default null,

    p_requiere_certificado boolean default false,

    p_sistema_presentacion text default null,

    p_activo boolean default true,

    p_observaciones text default null
  )
returns public.configuraciones_agentes_fiscales
language plpgsql
security definer
set search_path = public, auth
as $$
declare

  v_existente
    public.configuraciones_agentes_fiscales%rowtype;

  v_resultado
    public.configuraciones_agentes_fiscales%rowtype;

begin

  -- ==========================================================
  -- AUTENTICACIÓN / PERMISO
  -- ==========================================================

  if auth.uid() is null then
    raise exception 'Usuario no autenticado'
      using errcode = '42501';
  end if;


  if p_comercio_id is null then
    raise exception 'El comercio es obligatorio'
      using errcode = '22023';
  end if;


  perform public.exigir_permiso_comercio(
    p_comercio_id,
    'facturacion.configurar'
  );


  -- ==========================================================
  -- VALIDACIONES BÁSICAS
  -- ==========================================================

  if nullif(btrim(p_organismo), '') is null then
    raise exception 'El organismo es obligatorio'
      using errcode = '22023';
  end if;


  if nullif(btrim(p_impuesto), '') is null then
    raise exception 'El impuesto es obligatorio'
      using errcode = '22023';
  end if;


  if nullif(btrim(p_jurisdiccion), '') is null then
    raise exception 'La jurisdicción es obligatoria'
      using errcode = '22023';
  end if;


  if p_tipo_agente not in (
    'retencion',
    'percepcion'
  ) then
    raise exception
      'Tipo de agente inválido. Debe ser retencion o percepcion'
      using errcode = '22023';
  end if;


  if nullif(btrim(p_regimen_descripcion), '') is null then
    raise exception 'La descripción del régimen es obligatoria'
      using errcode = '22023';
  end if;


  if p_vigencia_desde is null then
    raise exception 'La fecha de inicio de vigencia es obligatoria'
      using errcode = '22023';
  end if;


  if
    p_vigencia_hasta is not null
    and p_vigencia_hasta < p_vigencia_desde
  then
    raise exception
      'La vigencia hasta no puede ser anterior a la vigencia desde'
      using errcode = '22023';
  end if;


  if p_modo_alicuota not in (
    'padron',
    'fija',
    'externa'
  ) then
    raise exception
      'Modo de alícuota inválido'
      using errcode = '22023';
  end if;


  if
    p_modo_alicuota = 'fija'
    and p_alicuota_fija is null
  then
    raise exception
      'Debe indicar una alícuota cuando el modo es fija'
      using errcode = '22023';
  end if;


  if
    p_modo_alicuota <> 'fija'
    and p_alicuota_fija is not null
  then
    raise exception
      'La alícuota fija solo puede utilizarse cuando el modo es fija'
      using errcode = '22023';
  end if;


  if
    p_alicuota_fija is not null
    and (
      p_alicuota_fija < 0
      or p_alicuota_fija > 100
    )
  then
    raise exception
      'La alícuota debe estar entre 0 y 100'
      using errcode = '22023';
  end if;


  -- ==========================================================
  -- CREAR
  -- ==========================================================

  if p_id is null then

    insert into public.configuraciones_agentes_fiscales (
      comercio_id,
      organismo,
      impuesto,
      jurisdiccion,
      tipo_agente,
      regimen_codigo,
      regimen_descripcion,
      numero_inscripcion_agente,
      vigencia_desde,
      vigencia_hasta,
      modo_alicuota,
      alicuota_fija,
      requiere_certificado,
      sistema_presentacion,
      activo,
      observaciones,
      creado_por,
      actualizado_por
    )
    values (
      p_comercio_id,
      btrim(p_organismo),
      btrim(p_impuesto),
      btrim(p_jurisdiccion),
      p_tipo_agente,

      nullif(
        btrim(p_regimen_codigo),
        ''
      ),

      btrim(p_regimen_descripcion),

      nullif(
        btrim(p_numero_inscripcion_agente),
        ''
      ),

      p_vigencia_desde,
      p_vigencia_hasta,
      p_modo_alicuota,
      p_alicuota_fija,

      coalesce(
        p_requiere_certificado,
        false
      ),

      nullif(
        btrim(p_sistema_presentacion),
        ''
      ),

      coalesce(
        p_activo,
        true
      ),

      nullif(
        btrim(p_observaciones),
        ''
      ),

      auth.uid(),
      auth.uid()
    )
    returning *
    into v_resultado;


  -- ==========================================================
  -- EDITAR
  -- ==========================================================

  else

    select *
    into v_existente
    from public.configuraciones_agentes_fiscales
    where id = p_id
    for update;


    if
      not found
      or v_existente.comercio_id <> p_comercio_id
    then
      raise exception
        'Configuración fiscal no encontrada'
        using errcode = 'P0002';
    end if;


    update public.configuraciones_agentes_fiscales
    set
      organismo =
        btrim(p_organismo),

      impuesto =
        btrim(p_impuesto),

      jurisdiccion =
        btrim(p_jurisdiccion),

      tipo_agente =
        p_tipo_agente,

      regimen_codigo =
        nullif(
          btrim(p_regimen_codigo),
          ''
        ),

      regimen_descripcion =
        btrim(p_regimen_descripcion),

      numero_inscripcion_agente =
        nullif(
          btrim(p_numero_inscripcion_agente),
          ''
        ),

      vigencia_desde =
        p_vigencia_desde,

      vigencia_hasta =
        p_vigencia_hasta,

      modo_alicuota =
        p_modo_alicuota,

      alicuota_fija =
        p_alicuota_fija,

      requiere_certificado =
        coalesce(
          p_requiere_certificado,
          false
        ),

      sistema_presentacion =
        nullif(
          btrim(p_sistema_presentacion),
          ''
        ),

      activo =
        coalesce(
          p_activo,
          true
        ),

      observaciones =
        nullif(
          btrim(p_observaciones),
          ''
        ),

      actualizado_por =
        auth.uid()

    where id = p_id

    returning *
    into v_resultado;

  end if;


  return v_resultado;


exception

  when unique_violation then

    raise exception
      'Ya existe una configuración activa para ese comercio, organismo, impuesto, jurisdicción, tipo de agente y régimen'
      using errcode = '23505';

end;
$$;


-- ============================================================
-- 3. DESACTIVAR CONFIGURACIÓN
--
-- Nunca hacemos DELETE físico.
-- La configuración conserva historial y auditoría.
-- ============================================================

create or replace function
  public.desactivar_configuracion_agente_fiscal(
    p_comercio_id uuid,
    p_configuracion_id uuid
  )
returns public.configuraciones_agentes_fiscales
language plpgsql
security definer
set search_path = public, auth
as $$
declare

  v_resultado
    public.configuraciones_agentes_fiscales%rowtype;

begin

  if auth.uid() is null then
    raise exception 'Usuario no autenticado'
      using errcode = '42501';
  end if;


  if p_comercio_id is null then
    raise exception 'El comercio es obligatorio'
      using errcode = '22023';
  end if;


  if p_configuracion_id is null then
    raise exception 'La configuración es obligatoria'
      using errcode = '22023';
  end if;


  perform public.exigir_permiso_comercio(
    p_comercio_id,
    'facturacion.configurar'
  );


  select *
  into v_resultado
  from public.configuraciones_agentes_fiscales
  where id = p_configuracion_id
  for update;


  if
    not found
    or v_resultado.comercio_id <> p_comercio_id
  then
    raise exception
      'Configuración fiscal no encontrada'
      using errcode = 'P0002';
  end if;


  if v_resultado.activo = false then
    return v_resultado;
  end if;


  update public.configuraciones_agentes_fiscales
  set
    activo = false,
    actualizado_por = auth.uid()
  where id = p_configuracion_id
  returning *
  into v_resultado;


  return v_resultado;

end;
$$;


-- ============================================================
-- 4. SEGURIDAD DE LAS RPC
-- ============================================================

revoke all
on function
  public.listar_configuraciones_agentes_fiscales(uuid)
from public, anon, authenticated;


grant execute
on function
  public.listar_configuraciones_agentes_fiscales(uuid)
to authenticated;



revoke all
on function
  public.guardar_configuracion_agente_fiscal(
    uuid,
    text,
    text,
    text,
    text,
    text,
    date,
    text,
    uuid,
    text,
    text,
    date,
    numeric,
    boolean,
    text,
    boolean,
    text
  )
from public, anon, authenticated;


grant execute
on function
  public.guardar_configuracion_agente_fiscal(
    uuid,
    text,
    text,
    text,
    text,
    text,
    date,
    text,
    uuid,
    text,
    text,
    date,
    numeric,
    boolean,
    text,
    boolean,
    text
  )
to authenticated;



revoke all
on function
  public.desactivar_configuracion_agente_fiscal(
    uuid,
    uuid
  )
from public, anon, authenticated;


grant execute
on function
  public.desactivar_configuracion_agente_fiscal(
    uuid,
    uuid
  )
to authenticated;


-- ============================================================
-- FIN PASO 12B.1.2
-- ============================================================