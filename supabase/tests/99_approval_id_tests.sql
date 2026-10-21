-- Aprobar exige el carnet aceptado y vigente (anverso y reverso). Corre después de 98.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000099d1', 'carnet-pro@test.bo', '{"full_name": "Pro Carnet", "city_id": "1"}');
select test.login('00000000-0000-0000-0000-0000000099d1');
select public.start_professional_application();
update public.professional_profiles set display_name = 'Pro Carnet', primary_category_id = 1, city_id = 1 where user_id = auth.uid();
insert into public.professional_documents (professional_id, doc_type, storage_path)
values (auth.uid(), 'ci_anverso', auth.uid() || '/a.jpg'), (auth.uid(), 'ci_reverso', auth.uid() || '/r.jpg');
select public.submit_professional_application();
-- El profesional no puede aceptar sus propios documentos.
update public.professional_documents set status = 'accepted' where professional_id = auth.uid();
select test.logout();
select test.eq((select count(*)::int from public.professional_documents
                 where professional_id = '00000000-0000-0000-0000-0000000099d1' and status = 'accepted'), 0,
               'carnet: el profesional no acepta sus propios documentos');

select test.login('00000000-0000-0000-0000-00000000000a');
select test.expect_error($$select public.review_professional_application('00000000-0000-0000-0000-0000000099d1', 'approved')$$,
                         'HMY_ID_DOCUMENTS_REQUIRED');
-- Solo el anverso aceptado no alcanza.
select public.admin_review_document((select id from public.professional_documents
  where professional_id = '00000000-0000-0000-0000-0000000099d1' and doc_type = 'ci_anverso'), 'accepted');
select test.expect_error($$select public.review_professional_application('00000000-0000-0000-0000-0000000099d1', 'approved')$$,
                         'HMY_ID_DOCUMENTS_REQUIRED');
select public.admin_review_document((select id from public.professional_documents
  where professional_id = '00000000-0000-0000-0000-0000000099d1' and doc_type = 'ci_reverso'), 'accepted');
select test.logout();
-- Un carnet vencido tampoco.
update public.professional_documents set expires_on = current_date - 1
 where professional_id = '00000000-0000-0000-0000-0000000099d1' and doc_type = 'ci_reverso';
select test.login('00000000-0000-0000-0000-00000000000a');
select test.expect_error($$select public.review_professional_application('00000000-0000-0000-0000-0000000099d1', 'approved')$$,
                         'HMY_ID_DOCUMENTS_REQUIRED');
select test.logout();
update public.professional_documents set expires_on = current_date + 365
 where professional_id = '00000000-0000-0000-0000-0000000099d1' and doc_type = 'ci_reverso';

select test.login('00000000-0000-0000-0000-00000000000a');
select public.review_professional_application('00000000-0000-0000-0000-0000000099d1', 'approved', 'Carnet revisado');
select test.logout();
select test.eq(public.has_role('professional', '00000000-0000-0000-0000-0000000099d1'), true,
               'carnet: con anverso y reverso aceptados, el equipo aprueba');

-- Levantar una suspensión no pide revisar el carnet de nuevo.
select test.login('00000000-0000-0000-0000-00000000000a');
select public.review_professional_application('00000000-0000-0000-0000-0000000099d1', 'suspended', 'Prueba');
select test.logout();
update public.professional_documents set status = 'pending' where professional_id = '00000000-0000-0000-0000-0000000099d1';
select test.login('00000000-0000-0000-0000-00000000000a');
select public.review_professional_application('00000000-0000-0000-0000-0000000099d1', 'approved', 'Suspensión levantada');
select test.logout();
select test.eq((select status from public.professional_profiles where user_id = '00000000-0000-0000-0000-0000000099d1')::text,
               'approved', 'carnet: levantar una suspensión no lo vuelve a pedir');

\o
\echo 'PRUEBAS DE CARNET PARA APROBAR PASARON'
