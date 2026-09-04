-- ============================================================
-- DRITO
-- PASO 18A.2
-- CUENTA DRITO - CONSULTA Y HABILITACIÓN MULTIEMPRESA
-- ============================================================


-- ============================================================
-- 1. CONSULTAR CUENTA DRITO DEL COMERCIO ACTIVO
-- ============================================================

create or replace function
public.obtener_cuenta_drito(
  p_comercio_id uuid
)
returns jsonb

language plpgsql
security definer
set search_path = public

as $$

declare

  v_cuenta public.cuentas_drito%rowtype;
  v_empresas jsonb;

begin

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;


  if not public.pertenece_a_comercio(p_comercio_id) then
    raise exception
      'El usuario no tiene acceso a este comercio';
  end if;


  select cd.*
  into v_cuenta

  from public.cuentas_drito cd

  join public.comercios c
    on c.cuenta_drito_id = cd.id

  where c.id = p_comercio_id;


  if not found then
    raise exception
      'No existe una Cuenta Drito asociada al comercio';
  end if;


  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', c.id,
        'nombre_comercial', c.nombre_comercial,
        'razon_social', c.razon_social,
        'cuit', c.cuit,
        'slug', c.slug,
        'activo', c.activo
      )
      order by c.created_at
    ),
    '[]'::jsonb
  )
  into v_empresas

  from public.comercios c

  where c.cuenta_drito_id = v_cuenta.id;


  return jsonb_build_object(

    'id',
      v_cuenta.id,

    'nombre',
      v_cuenta.nombre,

    'multiempresa_habilitada',
      v_cuenta.multiempresa_habilitada,

    'activo',
      v_cuenta.activo,

    'es_admin',
      public.es_admin_cuenta_drito(v_cuenta.id),

    'empresas',
      v_empresas

  );

end;

$$;



-- ============================================================
-- 2. HABILITAR MULTIEMPRESA
-- Sólo un administrador de la Cuenta Drito.
-- No crea empresas todavía.
-- ============================================================

create or replace function
public.habilitar_multiempresa(
  p_comercio_id uuid
)
returns jsonb

language plpgsql
security definer
set search_path = public

as $$

declare

  v_cuenta_id uuid;
  v_cuenta public.cuentas_drito%rowtype;

begin

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;


  select c.cuenta_drito_id
  into v_cuenta_id

  from public.comercios c

  where c.id = p_comercio_id;


  if not found then
    raise exception
      'El comercio no existe';
  end if;


  if not public.pertenece_a_comercio(p_comercio_id) then
    raise exception
      'El usuario no tiene acceso a este comercio';
  end if;


  if not public.es_admin_cuenta_drito(v_cuenta_id) then
    raise exception
      'Sólo un administrador puede habilitar Multiempresa';
  end if;


  update public.cuentas_drito

  set
    multiempresa_habilitada = true,
    updated_at = now()

  where id = v_cuenta_id

  returning *
  into v_cuenta;


  return jsonb_build_object(

    'id',
      v_cuenta.id,

    'nombre',
      v_cuenta.nombre,

    'multiempresa_habilitada',
      v_cuenta.multiempresa_habilitada,

    'activo',
      v_cuenta.activo

  );

end;

$$;



-- ============================================================
-- 3. SEGURIDAD
-- ============================================================

revoke all on function
public.obtener_cuenta_drito(uuid)
from public, anon;

revoke all on function
public.habilitar_multiempresa(uuid)
from public, anon;


grant execute on function
public.obtener_cuenta_drito(uuid)
to authenticated;

grant execute on function
public.habilitar_multiempresa(uuid)
to authenticated;