-- Rename vessel status from 'decommissioned' to 'archived' for consistency with container archiving
update vessels set status = 'archived' where status = 'decommissioned';
