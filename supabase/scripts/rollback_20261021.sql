-- PLAN DE REVERSIÓN (no se aplica solo). Deshace las migraciones del 21 de
-- octubre de 2026 (0030 a 0033) en el proyecto de DESARROLLO, en orden inverso
-- y en una sola transacción. Ninguna de ellas borró datos, así que revertir no
-- recupera nada: solo quita las reglas nuevas.
--
-- Antes de correrlo hay que cambiar a otra categoría a los profesionales que
-- ofrezcan Notario y borrar los documentos 'nombramiento_notarial', o el check
-- de documentos falla (por eso el script se detiene si existen).
--
-- Uso (solo con aprobación del dueño): psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/scripts/rollback_20261021.sql
\set ON_ERROR_STOP 1
begin;

-- 0033: catálogo
do $$ begin
  if exists (select 1 from public.professional_documents where doc_type = 'nombramiento_notarial')
     or exists (select 1 from public.professional_services s join public.service_categories c on c.id = s.category_id where c.slug = 'notario')
     or exists (select 1 from public.bookings b join public.service_categories c on c.id = b.category_id where c.slug = 'notario') then
    raise exception 'HMY: hay datos que usan Notario; revísalos antes de revertir';
  end if;
end $$;
delete from public.service_categories where slug = 'notario';
delete from public.service_problems where name = 'Churrasquero (parrillero)'
  and category_id = (select id from public.service_categories where slug = 'eventos');
update public.service_categories set description = 'Meseros, decoración y ayuda para fiestas'
where slug = 'eventos' and description = 'Meseros, churrasqueros, decoración y ayuda para fiestas';
alter table public.service_categories drop constraint service_categories_required_doc_check;
alter table public.service_categories add constraint service_categories_required_doc_check
  check (required_doc in ('antecedentes', 'certificado'));
alter table public.professional_documents drop constraint professional_documents_doc_type_check;
alter table public.professional_documents add constraint professional_documents_doc_type_check
  check (doc_type in ('ci_anverso', 'ci_reverso', 'certificado', 'antecedentes', 'otro'));

-- 0032: carnet para aprobar
drop trigger professional_profiles_id_documents_guard on public.professional_profiles;
drop function public.hmy_id_documents_guard();
drop function public.hmy_id_documents_accepted(uuid);

-- 0031: foto de perfil en la carpeta propia
alter table public.professional_profiles drop constraint professional_photo_own_folder;
alter table public.profiles drop constraint profiles_avatar_own_folder;

-- 0030: vuelve la versión original de acknowledge_payment (20261019000300).
create or replace function public.acknowledge_payment(p_booking uuid, p_method public.payment_method)
returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'HMY_NOT_FOUND'; end if;
  if b.status not in ('work_finished', 'completed') then raise exception 'HMY_INVALID_TRANSITION'; end if;
  if b.customer_id = auth.uid() then
    update public.bookings set customer_paid_ack_at = coalesce(customer_paid_ack_at, now()),
           payment_method = coalesce(payment_method, p_method) where id = p_booking;
  elsif b.professional_id = auth.uid() then
    update public.bookings set professional_paid_ack_at = coalesce(professional_paid_ack_at, now()),
           payment_method = coalesce(payment_method, p_method) where id = p_booking;
  else
    raise exception 'HMY_FORBIDDEN';
  end if;
end $$;
revoke execute on function public.acknowledge_payment(uuid, public.payment_method) from public, anon;

delete from supabase_migrations.schema_migrations
where version in ('20261021003000', '20261021003100', '20261021003200', '20261021003300');
commit;
