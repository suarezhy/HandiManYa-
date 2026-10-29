-- Deshace 0059: vuelve a create_ya_request de 0057.
create or replace function public.create_ya_request(
  p_category int,
  p_city smallint,
  p_description text,
  p_address text,
  p_address_reference text default null,
  p_zone_id int default null,
  p_payment_method public.payment_method default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_problem_ids int[] default null,
  p_other_text text default null,
  p_destination text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_open uuid;
begin
  if v_me is null then raise exception 'HMY_AUTH_REQUIRED'; end if;
  -- Dos llamadas a la vez de la misma persona y servicio esperan una a la otra.
  perform pg_advisory_xact_lock(hashtextextended('hmy_ya:' || v_me::text || ':' || p_category::text, 0));
  select b.id into v_open from public.bookings b
  where b.customer_id = v_me and b.category_id = p_category and b.mode = 'now'
    and b.status = 'awaiting_response' and b.professional_id is null
    and public.hmy_response_deadline(b) > now()
  order by b.created_at desc
  limit 1;
  if v_open is not null then return v_open; end if;
  return public._create_ya_request_extras(p_category, p_city, p_description, p_address, p_address_reference,
    p_zone_id, p_payment_method, p_latitude, p_longitude, p_problem_ids, p_other_text, p_destination);
end $$;
