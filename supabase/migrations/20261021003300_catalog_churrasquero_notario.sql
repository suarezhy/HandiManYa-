-- Catálogo: Churrasquero en Eventos y Notario de fe pública junto a Asesoría
-- legal. No cambia ningún identificador existente.
--
-- El notario es una función pública regulada (Ley 483 del Notariado
-- Plurinacional y su reglamento, DS 2189): lo nombra la Dirección del Notariado
-- Plurinacional (DIRNOPLU) por resolución, para un territorio, y el arancel lo
-- fija la DIRNOPLU. Por eso pide su propio documento (la resolución de
-- nombramiento), distinto de la matrícula de abogado: un abogado aceptado para
-- Asesoría legal no queda habilitado como notario.

alter table public.professional_documents drop constraint professional_documents_doc_type_check;
alter table public.professional_documents add constraint professional_documents_doc_type_check
  check (doc_type in ('ci_anverso', 'ci_reverso', 'certificado', 'antecedentes', 'nombramiento_notarial', 'otro'));

alter table public.service_categories drop constraint service_categories_required_doc_check;
alter table public.service_categories add constraint service_categories_required_doc_check
  check (required_doc in ('antecedentes', 'certificado', 'nombramiento_notarial'));

update public.service_categories set description = 'Meseros, churrasqueros, decoración y ayuda para fiestas'
where slug = 'eventos' and description = 'Meseros, decoración y ayuda para fiestas';

insert into public.service_problems (category_id, name, icon, is_other, sort_order)
select id, 'Churrasquero (parrillero)', 'outdoor_grill', false, 65 from public.service_categories where slug = 'eventos'
on conflict (category_id, name) do nothing;

insert into public.service_categories (slug, name, icon, description, sort_order, required_doc, allows_ya, safety_note, pro_note)
values ('notario', 'Notario de fe pública', 'history_edu', 'Poderes, firmas y documentos con un notario nombrado', 19,
  'nombramiento_notarial', false,
  'Pide ver la resolución de nombramiento del notario y su número de notaría. El arancel lo fija la Dirección del Notariado Plurinacional (DIRNOPLU): pide el detalle antes de firmar. La app solo los pone en contacto.',
  'Para ofrecer servicios de notario necesitas subir tu resolución de nombramiento de la DIRNOPLU (vigente y con tu notaría y territorio) y que el equipo la acepte. Cobra según el arancel oficial.')
on conflict (slug) do nothing;

insert into public.service_problems (category_id, name, icon, is_other, sort_order)
select c.id, p.name, p.icon, p.is_other, p.sort_order
from public.service_categories c
cross join (values
  ('Poderes', 'assignment', false, 10),
  ('Reconocimiento de firmas', 'description', false, 20),
  ('Copias legalizadas', 'description', false, 30),
  ('Minutas y escrituras', 'gavel', false, 40)
) as p(name, icon, is_other, sort_order)
where c.slug = 'notario'
on conflict (category_id, name) do nothing;

-- La categoría nueva ya trae su opción "Otro" (add_default_problem); solo se
-- le pone un nombre propio y va al final de la lista.
update public.service_problems set name = 'Otro trámite notarial', sort_order = 50
where is_other and name = 'Otro servicio'
  and category_id = (select id from public.service_categories where slug = 'notario');
