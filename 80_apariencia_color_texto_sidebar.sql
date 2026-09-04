begin;

alter table public.configuraciones_comercio
  add column if not exists color_texto_sidebar text
  not null default '#ffffff';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname =
      'configuraciones_comercio_color_texto_sidebar_check'
  ) then
    alter table public.configuraciones_comercio
      add constraint
      configuraciones_comercio_color_texto_sidebar_check
      check (
        color_texto_sidebar in (
          '#ffffff',
          '#111827'
        )
      );
  end if;
end;
$$;

commit;
