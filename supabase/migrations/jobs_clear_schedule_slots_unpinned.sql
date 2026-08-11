-- Next 5 is fully auto from Job Ready; clear any legacy/manual slots and pins.
UPDATE jobs
SET schedule_slot = NULL,
    schedule_slot_pinned = false
WHERE schedule_slot IS NOT NULL
   OR schedule_slot_pinned = true;
