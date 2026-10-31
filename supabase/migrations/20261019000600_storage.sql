-- HandiMan ¡Ya! — 0006 almacenamiento de archivos.
-- Convención: la primera carpeta de la ruta identifica al dueño
-- (id de usuario, de reserva o de conversación).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('avatars', 'avatars', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('portfolio', 'portfolio', true, 8388608, array['image/jpeg', 'image/png', 'image/webp']),
  ('professional-documents', 'professional-documents', false, 10485760,
   array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']),
  ('booking-photos', 'booking-photos', false, 8388608, array['image/jpeg', 'image/png', 'image/webp']),
  ('chat-images', 'chat-images', false, 8388608, array['image/jpeg', 'image/png', 'image/webp']),
  ('topup-proofs', 'topup-proofs', false, 8388608,
   array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']),
  ('payment-qr', 'payment-qr', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create function public.storage_owner_folder(p_name text) returns text
language sql immutable as $$
  select (storage.foldername(p_name))[1]
$$;

create function public.uuid_or_null(p text) returns uuid
language plpgsql immutable as $$
begin
  return p::uuid;
exception when others then
  return null;
end $$;

-- Fotos públicas: cada usuario escribe solo en su carpeta.
create policy "hmy public read" on storage.objects for select
  using (bucket_id in ('avatars', 'portfolio'));
create policy "hmy own write" on storage.objects for insert to authenticated
  with check (bucket_id in ('avatars', 'portfolio', 'professional-documents', 'topup-proofs', 'payment-qr')
              and public.storage_owner_folder(name) = auth.uid()::text);
create policy "hmy own update" on storage.objects for update to authenticated
  using (bucket_id in ('avatars', 'portfolio', 'payment-qr') and public.storage_owner_folder(name) = auth.uid()::text);
create policy "hmy own delete" on storage.objects for delete to authenticated
  using (bucket_id in ('avatars', 'portfolio', 'payment-qr') and public.storage_owner_folder(name) = auth.uid()::text);

-- Documentos de identidad y comprobantes: dueño y administrador.
create policy "hmy private own read" on storage.objects for select to authenticated
  using (bucket_id in ('professional-documents', 'topup-proofs', 'payment-qr')
         and (public.storage_owner_folder(name) = auth.uid()::text or public.is_admin()));

-- QR de cobro: también lo ve el cliente con un trabajo activo con ese profesional.
create policy "hmy payment qr customer read" on storage.objects for select to authenticated
  using (bucket_id = 'payment-qr' and exists (
    select 1 from public.bookings b
    where b.professional_id = public.uuid_or_null(public.storage_owner_folder(name))
      and b.customer_id = auth.uid()
      and b.status in ('in_progress', 'work_finished', 'completed')));

-- Fotos del problema y evidencia: participantes de la reserva.
create policy "hmy booking photos read" on storage.objects for select to authenticated
  using (bucket_id = 'booking-photos'
         and (public.is_booking_participant(public.uuid_or_null(public.storage_owner_folder(name))) or public.is_admin()));
create policy "hmy booking photos write" on storage.objects for insert to authenticated
  with check (bucket_id = 'booking-photos'
              and public.is_booking_participant(public.uuid_or_null(public.storage_owner_folder(name))));

-- Imágenes del chat: participantes de la conversación.
create policy "hmy chat images read" on storage.objects for select to authenticated
  using (bucket_id = 'chat-images'
         and public.is_conversation_participant(public.uuid_or_null(public.storage_owner_folder(name))));
create policy "hmy chat images write" on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-images'
              and public.is_conversation_participant(public.uuid_or_null(public.storage_owner_folder(name))));
