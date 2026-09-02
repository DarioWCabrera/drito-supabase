-- ============================================================
-- DRITO
-- 12B.3.2 - Certificados de retenciones practicadas
-- Archivo:
-- 41_paso12b3_2_certificados_retenciones_practicadas.sql
--
-- Objetivos:
-- 1. Crear permiso específico para gestionar certificados.
-- 2. Asignarlo por defecto únicamente al rol admin.
-- 3. Crear bucket privado para certificados.
-- 4. Proteger Storage por comercio + permisos.
-- 5. Crear RPC segura para asociar número/path a una retención.
--
-- Regla:
-- - compras.ver => consultar / descargar.
-- - compras.gestionar_certificados_retenciones => subir / reemplazar /
--   asociar certificado.
-- - No se permite DELETE de certificados vía cliente.
-- ============================================================

begin;

-- ============================================================
-- 1. Permiso específico
-- ============================================================

insert into public.permisos_sistema (
  codigo,
  modulo,
  accion,
  nombre,
  descripcion,
  sensible,
  orden,
  activo,
  created_at,
  updated_at
)
select
  'compras.gestionar_certificados_retenciones',
  'compras',
  'gestionar_certificados_retenciones',
  'Gestionar certificados de retenciones',
  'Subir, reemplazar y asociar certificados de retenciones practicadas.',
  true,
  coalesce(
    (
      select max(ps.orden)
      from public.permisos_sistema ps
      where ps.modulo = 'compras'
    ),
    0
  ) + 1,
  true,
  now(),
  now()
where not exists (
  select 1
  from public.permisos_sistema ps
  where ps.codigo = 'compras.gestionar_certificados_retenciones'
);

-- ============================================================
-- 2. Permiso por defecto solo para admin
-- ============================================================

insert into public.roles_permisos (
  rol,
  permiso_codigo,
  permitido,
  created_at
)
select
  'admin',
  'compras.gestionar_certificados_retenciones',
  true,
  now()
where not exists (
  select 1
  from public.roles_permisos rp
  where rp.rol = 'admin'
    and rp.permiso_codigo = 'compras.gestionar_certificados_retenciones'
);

-- ============================================================
-- 3. Bucket privado
-- ============================================================

insert into storage.buckets (
  id,
  name,
  public
)
values (
  'certificados-retenciones',
  'certificados-retenciones',
  false
)
on conflict (id) do update
set
  name = excluded.name,
  public = false;

-- ============================================================
-- 4. Policies Storage
--
-- Estructura obligatoria del path:
--
-- <comercio_id>/<retencion_id>/<archivo>.pdf
--
-- Ejemplo:
-- 60840da6-f45a-44e0-9dca-6d42cc705604/
-- 123e4567-e89b-12d3-a456-426614174000/
-- certificado.pdf
-- ============================================================

drop policy if exists
  certificados_retenciones_select
on storage.objects;

create policy certificados_retenciones_select
on storage.objects
for select
to authenticated
using (
  bucket_id = 'certificados-retenciones'

  and split_part(name, '/', 1)
    ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

  and (
    public.tiene_permiso_comercio(
      split_part(name, '/', 1)::uuid,
      'compras.ver'
    )
    or
    public.tiene_permiso_comercio(
      split_part(name, '/', 1)::uuid,
      'compras.gestionar_certificados_retenciones'
    )
  )
);

drop policy if exists
  certificados_retenciones_insert
on storage.objects;

create policy certificados_retenciones_insert
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'certificados-retenciones'

  and split_part(name, '/', 1)
    ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

  and split_part(name, '/', 2)
    ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

  and split_part(name, '/', 3) <> ''

  and name ~* '\.pdf$'

  and public.tiene_permiso_comercio(
    split_part(name, '/', 1)::uuid,
    'compras.gestionar_certificados_retenciones'
  )
);

drop policy if exists
  certificados_retenciones_update
on storage.objects;

create policy certificados_retenciones_update
on storage.objects
for update
to authenticated
using (
  bucket_id = 'certificados-retenciones'

  and split_part(name, '/', 1)
    ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

  and public.tiene_permiso_comercio(
    split_part(name, '/', 1)::uuid,
    'compras.gestionar_certificados_retenciones'
  )
)
with check (
  bucket_id = 'certificados-retenciones'

  and split_part(name, '/', 1)
    ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

  and split_part(name, '/', 2)
    ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

  and split_part(name, '/', 3) <> ''

  and name ~* '\.pdf$'

  and public.tiene_permiso_comercio(
    split_part(name, '/', 1)::uuid,
    'compras.gestionar_certificados_retenciones'
  )
);

-- IMPORTANTE:
-- No se crea policy DELETE.
-- Los certificados asociados quedan preservados como evidencia fiscal.

-- ============================================================
-- 5. RPC segura para asociar certificado
-- ============================================================

create or replace function public.guardar_certificado_retencion_practicada(
  p_retencion_id uuid,
  p_numero_certificado text default null,
  p_certificado_storage_path text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_retencion public.retenciones_practicadas%rowtype;

  v_numero text;
  v_path text;

  v_comercio_path text;
  v_retencion_path text;

  v_objeto_existe boolean;
begin

  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  select rp.*
  into v_retencion
  from public.retenciones_practicadas rp
  where rp.id = p_retencion_id
  for update;

  if not found then
    raise exception 'La retención practicada no existe';
  end if;

  perform public.exigir_permiso_comercio(
    v_retencion.comercio_id,
    'compras.gestionar_certificados_retenciones'
  );

  if v_retencion.estado = 'anulada' then
    raise exception
      'No se puede modificar el certificado de una retención anulada';
  end if;

  v_numero :=
    nullif(btrim(p_numero_certificado), '');

  v_path :=
    nullif(btrim(p_certificado_storage_path), '');

  -- Si un dato no vino informado, conservar el existente.
  if v_numero is null then
    v_numero := v_retencion.numero_certificado;
  end if;

  if v_path is null then
    v_path := v_retencion.certificado_storage_path;
  end if;

  if v_numero is null and v_path is null then
    raise exception
      'Debe informar número de certificado, archivo o ambos';
  end if;

  -- ==========================================================
  -- Validación fuerte del archivo
  -- ==========================================================

  if v_path is not null then

    if v_path !~* '\.pdf$' then
      raise exception
        'El certificado debe ser un archivo PDF';
    end if;

    v_comercio_path :=
      split_part(v_path, '/', 1);

    v_retencion_path :=
      split_part(v_path, '/', 2);

    if v_comercio_path <> v_retencion.comercio_id::text then
      raise exception
        'El archivo no pertenece al comercio de la retención';
    end if;

    if v_retencion_path <> v_retencion.id::text then
      raise exception
        'El archivo no pertenece a la retención indicada';
    end if;

    if split_part(v_path, '/', 3) = '' then
      raise exception
        'La ruta del certificado es inválida';
    end if;

    select exists (
      select 1
      from storage.objects so
      where so.bucket_id = 'certificados-retenciones'
        and so.name = v_path
    )
    into v_objeto_existe;

    if not v_objeto_existe then
      raise exception
        'El archivo indicado no existe en Storage';
    end if;

  end if;

  -- ==========================================================
  -- Asociación segura
  -- ==========================================================

  update public.retenciones_practicadas
  set
    numero_certificado = v_numero,
    certificado_storage_path = v_path,
    updated_at = now()
  where id = v_retencion.id;

  return jsonb_build_object(
    'ok', true,
    'retencion_id', v_retencion.id,
    'comercio_id', v_retencion.comercio_id,
    'numero_certificado', v_numero,
    'certificado_storage_path', v_path
  );

end;
$function$;

revoke all
on function public.guardar_certificado_retencion_practicada(
  uuid,
  text,
  text
)
from public;

grant execute
on function public.guardar_certificado_retencion_practicada(
  uuid,
  text,
  text
)
to authenticated;

commit;