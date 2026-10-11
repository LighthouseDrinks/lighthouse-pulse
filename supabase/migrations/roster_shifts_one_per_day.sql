-- One roster row per person per day. Extra copies of the same cell were
-- invisible on the roster (it keeps one shift in memory) and were added
-- together on the hours report.

delete from public.roster_shifts a
using (
  select id,
         row_number() over (
           partition by user_id, shift_date
           order by created_at desc nulls last, id desc
         ) as rn
  from public.roster_shifts
  where user_id is not null
) ranked
where a.id = ranked.id
  and ranked.rn > 1;

create unique index if not exists roster_shifts_user_date_uidx
  on public.roster_shifts (user_id, shift_date);
