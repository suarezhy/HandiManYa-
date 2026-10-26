-- Catálogo: Churrasquero y Notario (0033). Corre después de 99.
\set ON_ERROR_STOP 1
\o /dev/null

select test.eq((select count(*)::int from public.service_problems p join public.service_categories c on c.id = p.category_id
                 where c.slug = 'eventos' and p.name = 'Churrasquero (parrillero)' and p.is_active), 1,
               'catálogo: Eventos ofrece Churrasquero');
select test.eq((select description from public.service_categories where slug = 'eventos'),
               'Meseros, churrasqueros, bandas, decoración y ayuda para fiestas', 'catálogo: la búsqueda de Eventos incluye churrasqueros (y bandas, 0049)');
select test.eq((select (required_doc, allows_ya, is_active)::text from public.service_categories where slug = 'notario'),
               '(nombramiento_notarial,f,t)', 'catálogo: Notario pide su nombramiento y no es ¡Ya!');
select test.eq((select id from public.service_categories where slug = 'asesoria-legal'), 18, 'catálogo: Asesoría legal conserva su id');
select test.eq((select id from public.service_categories where slug = 'eventos'), 17, 'catálogo: Eventos conserva su id');
select test.eq((select count(*)::int from public.service_problems p join public.service_categories c on c.id = p.category_id
                 where c.slug = 'notario' and p.is_other), 1, 'catálogo: Notario tiene una opción "Otro"');

-- Un abogado aceptado para Asesoría legal no queda habilitado como notario.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000099e1', 'notario@test.bo', '{"full_name": "Abogada Notaria"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id)
values ('00000000-0000-0000-0000-0000000099e1', 'Abogada Notaria', 18, 1);
insert into public.professional_documents (professional_id, doc_type, storage_path, status)
values ('00000000-0000-0000-0000-0000000099e1', 'certificado', '00000000-0000-0000-0000-0000000099e1/matricula.jpg', 'accepted');
select test.eq(public.hmy_pro_cleared('00000000-0000-0000-0000-0000000099e1', 18), true, 'notario: la matrícula habilita Asesoría legal');
select test.eq(public.hmy_pro_cleared('00000000-0000-0000-0000-0000000099e1',
                 (select id from public.service_categories where slug = 'notario')), false,
               'notario: la matrícula de abogado no alcanza para ofrecer servicios notariales');
insert into public.professional_documents (professional_id, doc_type, storage_path, status)
values ('00000000-0000-0000-0000-0000000099e1', 'nombramiento_notarial', '00000000-0000-0000-0000-0000000099e1/nombramiento.pdf', 'pending');
select test.eq(public.hmy_pro_cleared('00000000-0000-0000-0000-0000000099e1',
                 (select id from public.service_categories where slug = 'notario')), false,
               'notario: el nombramiento sin revisar no alcanza');
update public.professional_documents set status = 'accepted'
 where professional_id = '00000000-0000-0000-0000-0000000099e1' and doc_type = 'nombramiento_notarial';
select test.eq(public.hmy_pro_cleared('00000000-0000-0000-0000-0000000099e1',
                 (select id from public.service_categories where slug = 'notario')), true,
               'notario: con el nombramiento aceptado por el equipo queda habilitado');

\o
\echo 'PRUEBAS DEL CATÁLOGO PASARON'
