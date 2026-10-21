-- Aprobar a un profesional exige su carnet (anverso y reverso) aceptado y
-- vigente. Antes solo se pedía haber subido algún documento para postular, y el
-- agente de reglas avisaba después si había un aprobado sin carnet aceptado.
-- Levantar una suspensión no cambia: ese profesional ya pasó la revisión.
create or replace function public.hmy_id_documents_accepted(p_pro uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select count(distinct d.doc_type) = 2
  from public.professional_documents d
  where d.professional_id = p_pro and d.doc_type in ('ci_anverso', 'ci_reverso') and d.status = 'accepted'
    and (d.expires_on is null or d.expires_on >= current_date)
$$;
revoke execute on function public.hmy_id_documents_accepted(uuid) from public, anon, authenticated;

create or replace function public.hmy_id_documents_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' and old.status <> 'suspended'
     and not public.hmy_id_documents_accepted(new.user_id) then
    raise exception 'HMY_ID_DOCUMENTS_REQUIRED';
  end if;
  return new;
end $$;
revoke execute on function public.hmy_id_documents_guard() from public, anon, authenticated;

create trigger professional_profiles_id_documents_guard before update of status on public.professional_profiles
  for each row execute function public.hmy_id_documents_guard();
