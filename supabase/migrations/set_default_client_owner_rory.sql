-- Assign a default Lighthouse account contact (owner_id) to every client that
-- currently has none. Previously all clients had a null owner_id, so the portal
-- fell back to a hardcoded, now-terminated employee. Rory O'Leary (active,
-- commercial_manager) becomes the default contact; staff can override per client
-- via the client editor.
--
-- clients.owner_id is text; app_users.id is uuid, so the id is stored as text
-- to match the existing join (au.id::text = c.owner_id).

update clients
   set owner_id = '4b5569bf-b26c-4df7-84c7-1d6c9a4e8ba2'
 where owner_id is null or btrim(owner_id) = '';
