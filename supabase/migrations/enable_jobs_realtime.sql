-- Enable Supabase Realtime for the jobs table so the plant display
-- receives live updates when start / pause / resume / finish are pressed.
-- Run this once in the Supabase SQL editor (project dashboard → SQL Editor).

alter publication supabase_realtime add table jobs;
