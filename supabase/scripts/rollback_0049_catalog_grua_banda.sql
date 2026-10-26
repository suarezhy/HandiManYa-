-- PLAN DE REVERSIÓN (no se aplica solo). Deshace la migración 0049
-- (20261026004900_catalog_grua_banda) en el proyecto de DESARROLLO.
-- Se niega si ya hay pedidos o documentos de grúa: esos datos no se borran.
--
-- Uso (solo con aprobación del dueño):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_0049_catalog_grua_banda.sql
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if exists (select 1 from public.bookings b join public.service_categories c on c.id = b.category_id where c.slug = 'grua')
     or exists (select 1 from public.professional_documents where doc_type = 'documentos_grua')
     or exists (select 1 from public.booking_addresses where destination is not null) then
    raise exception 'HMY: ya hay pedidos o documentos de grúa; no se revirtió nada.';
  end if;
end $$;
drop function public.booking_detail(uuid);
alter function public._booking_detail_problems(uuid) rename to booking_detail;
drop function public.create_booking(uuid, int, public.booking_mode, text, text, text, int, timestamptz, int,
  public.payment_method, numeric, numeric, int[], text, text);
alter function public._create_booking_problems(uuid, int, public.booking_mode, text, text, text, int, timestamptz, int,
  public.payment_method, numeric, numeric, int[], text) rename to create_booking;
drop function public.create_ya_request(int, smallint, text, text, text, int, public.payment_method, numeric, numeric,
  int[], text, text);
alter function public._create_ya_request_problems(int, smallint, text, text, text, int, public.payment_method, numeric,
  numeric, int[], text) rename to create_ya_request;
drop function public.hmy_check_booking_extras(int, int[], text);
do $$
declare f text;
begin
  foreach f in array array[
    'public.create_booking(uuid, int, public.booking_mode, text, text, text, int, timestamptz, int, public.payment_method, numeric, numeric, int[], text)',
    'public.create_ya_request(int, smallint, text, text, text, int, public.payment_method, numeric, numeric, int[], text)',
    'public.booking_detail(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
alter table public.booking_addresses drop column destination;
delete from public.service_problems where name = 'Banda'
  and category_id = (select id from public.service_categories where slug = 'eventos');
update public.service_categories set description = 'Meseros, churrasqueros, decoración y ayuda para fiestas'
  where slug = 'eventos';
update public.service_categories set description = 'Mecánico a domicilio y auxilio' where slug = 'mecanica';
delete from public.service_problems where opens_category_id is not null;
delete from public.service_problems where category_id = (select id from public.service_categories where slug = 'grua');
delete from public.professional_services where category_id = (select id from public.service_categories where slug = 'grua');
delete from public.service_categories where slug = 'grua';
alter table public.service_problems drop column opens_category_id;
create or replace function public.hmy_pro_cleared(p_pro uuid, p_category int) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select c.required_doc is null or exists (
      select 1 from public.professional_documents d
      where d.professional_id = p_pro and d.doc_type = c.required_doc and d.status = 'accepted'
        and (d.expires_on is null or d.expires_on >= current_date))
    from public.service_categories c where c.id = p_category), false)
$$;
revoke execute on function public.hmy_pro_cleared(uuid, int) from public, anon, authenticated;
alter table public.service_categories drop constraint service_categories_required_doc_check;
alter table public.service_categories add constraint service_categories_required_doc_check
  check (required_doc in ('antecedentes', 'certificado', 'nombramiento_notarial'));
alter table public.professional_documents drop constraint professional_documents_doc_type_check;
alter table public.professional_documents add constraint professional_documents_doc_type_check
  check (doc_type in ('ci_anverso', 'ci_reverso', 'certificado', 'antecedentes', 'nombramiento_notarial', 'otro'));
delete from supabase_migrations.schema_migrations where version = '20261026004900';
commit;
