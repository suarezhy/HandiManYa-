-- HandiMan ¡Ya! — 0004 mensajería en tiempo real ligada a cada reserva.

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings(id) on delete cascade,
  customer_id uuid not null references public.profiles(id),
  professional_id uuid not null references public.profiles(id),
  last_message_at timestamptz,
  last_message_preview text,
  created_at timestamptz not null default now()
);

create table public.messages (
  id bigserial primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id),
  body text check (body is null or char_length(body) between 1 and 2000),
  image_path text,
  created_at timestamptz not null default now(),
  check (body is not null or image_path is not null)
);
create index messages_conversation_idx on public.messages (conversation_id, created_at);

create table public.conversation_reads (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create function public.is_conversation_participant(p_conversation uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.conversations c where c.id = p_conversation
                 and (c.customer_id = auth.uid() or c.professional_id = auth.uid()))
$$;

-- El chat se abre cuando la reserva se confirma.
create function public.open_conversation_on_confirm() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'confirmed' and old.status is distinct from 'confirmed' and new.professional_id is not null then
    insert into public.conversations (booking_id, customer_id, professional_id)
    values (new.id, new.customer_id, new.professional_id)
    on conflict (booking_id) do nothing;
  end if;
  return new;
end $$;

create trigger bookings_open_conversation after update of status on public.bookings
  for each row execute function public.open_conversation_on_confirm();

-- Solo se puede escribir mientras el trabajo está activo o en disputa.
create function public.send_message(p_conversation uuid, p_body text default null, p_image_path text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  c public.conversations;
  v_status public.booking_status;
  v_id bigint;
  v_other uuid;
begin
  select * into c from public.conversations where id = p_conversation;
  if not found or auth.uid() not in (c.customer_id, c.professional_id) then raise exception 'HMY_FORBIDDEN'; end if;
  select status into v_status from public.bookings where id = c.booking_id;
  if v_status not in ('confirmed', 'on_the_way', 'in_progress', 'work_finished', 'completed', 'disputed') then
    raise exception 'HMY_CHAT_CLOSED';
  end if;
  if p_image_path is not null and p_image_path not like c.id::text || '/%' then
    raise exception 'HMY_INVALID_ATTACHMENT';
  end if;
  insert into public.messages (conversation_id, sender_id, body, image_path)
  values (c.id, auth.uid(), nullif(trim(p_body), ''), p_image_path)
  returning id into v_id;

  update public.conversations
  set last_message_at = now(),
      last_message_preview = coalesce(left(nullif(trim(p_body), ''), 80), '📷 Foto')
  where id = c.id;

  insert into public.conversation_reads (conversation_id, user_id, last_read_at)
  values (c.id, auth.uid(), now())
  on conflict (conversation_id, user_id) do update set last_read_at = excluded.last_read_at;

  v_other := case when auth.uid() = c.customer_id then c.professional_id else c.customer_id end;
  perform public.notify(v_other, 'message', 'Nuevo mensaje',
                        coalesce(left(nullif(trim(p_body), ''), 80), '📷 Foto'),
                        jsonb_build_object('conversation_id', c.id, 'booking_id', c.booking_id));
  return v_id;
end $$;

create function public.mark_conversation_read(p_conversation uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_conversation_participant(p_conversation) then raise exception 'HMY_FORBIDDEN'; end if;
  insert into public.conversation_reads (conversation_id, user_id, last_read_at)
  values (p_conversation, auth.uid(), now())
  on conflict (conversation_id, user_id) do update set last_read_at = excluded.last_read_at;
end $$;

-- Lista de chats del usuario con nombre del otro participante y no leídos.
create function public.my_conversations()
returns table (
  id uuid, booking_id uuid, booking_code text, other_user_id uuid, other_name text,
  last_message_at timestamptz, last_message_preview text, unread_count int, booking_status public.booking_status
)
language sql stable security definer set search_path = public as $$
  select c.id, c.booking_id, b.code,
         case when c.customer_id = auth.uid() then c.professional_id else c.customer_id end,
         case when c.customer_id = auth.uid()
              then coalesce(nullif(pp.display_name, ''), 'Profesional')
              else coalesce(nullif(split_part(cp.full_name, ' ', 1), ''), 'Cliente') end,
         c.last_message_at, c.last_message_preview,
         (select count(*)::int from public.messages m
          where m.conversation_id = c.id and m.sender_id <> auth.uid()
            and m.created_at > coalesce((select r.last_read_at from public.conversation_reads r
                                         where r.conversation_id = c.id and r.user_id = auth.uid()),
                                        '-infinity'::timestamptz)),
         b.status
  from public.conversations c
  join public.bookings b on b.id = c.booking_id
  left join public.professional_profiles pp on pp.user_id = c.professional_id
  left join public.profiles cp on cp.id = c.customer_id
  where c.customer_id = auth.uid() or c.professional_id = auth.uid()
  order by coalesce(c.last_message_at, c.created_at) desc
$$;

alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.conversation_reads enable row level security;

create policy conversations_participants on public.conversations for select
  using (customer_id = auth.uid() or professional_id = auth.uid() or public.is_admin());
create policy messages_participants on public.messages for select
  using (public.is_conversation_participant(conversation_id));
create policy reads_own on public.conversation_reads for select using (user_id = auth.uid());

revoke insert, update, delete on public.conversations from anon, authenticated;
revoke insert, update, delete on public.messages from anon, authenticated;
revoke insert, update, delete on public.conversation_reads from anon, authenticated;

-- Realtime respeta RLS: cada usuario solo recibe los mensajes de sus chats.
alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.notifications;
alter publication supabase_realtime add table public.bookings;

revoke execute on function public.open_conversation_on_confirm() from public, anon, authenticated;
revoke execute on function public.send_message(uuid, text, text) from public, anon;
revoke execute on function public.mark_conversation_read(uuid) from public, anon;
revoke execute on function public.my_conversations() from public, anon;
