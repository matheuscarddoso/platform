-- pg_cron jobs exported from Supabase Cloud (cron.job is not part of the data dump).
-- Created INACTIVE; scripts/activate-crons.sql turns them on only on the production cutover.
select cron.unschedule(jobid) from cron.job;
select cron.schedule($cron$courier-positions-cleanup$cron$, $cron$0 7 * * *$cron$, $cron$
      delete from public.courier_positions where received_at < now() - interval '30 days';
      update public.couriers c set last_lat = null, last_lon = null
       where c.last_lat is not null and c.last_seen_at < now() - interval '1 hour'
         and not exists (select 1 from public.delivery_runs r where r.courier_id = c.id and r.status = 'em_rota');
    $cron$);
select cron.schedule($cron$crm-daily$cron$, $cron$10 8 * * *$cron$, $cron$select public.crm_run_daily()$cron$);
select cron.schedule($cron$crm-metrics$cron$, $cron$0 8 * * *$cron$, $cron$select public.refresh_all_client_metrics()$cron$);
select cron.schedule($cron$crm-notify$cron$, $cron$*/10 12-23 * * *$cron$, $cron$select public.crm_notify_tick()$cron$);
select cron.schedule($cron$crm-tick$cron$, $cron$*/5 * * * *$cron$, $cron$select public.crm_tick()$cron$);
select cron.schedule($cron$finance-recurrences$cron$, $cron$0 7 * * *$cron$, $cron$select public.materialize_financial_recurrences()$cron$);
select cron.schedule($cron$fiscal-worker$cron$, $cron$* * * * *$cron$, $cron$select public.fiscal_worker_tick()$cron$);
select cron.schedule($cron$loyalty-expire$cron$, $cron$0 7 * * *$cron$, $cron$select public.loyalty_expire()$cron$);
select cron.schedule($cron$marketplace-cleanup$cron$, $cron$30 6 * * *$cron$, $cron$select public.marketplace_cleanup()$cron$);
select cron.schedule($cron$marketplace-poll$cron$, $cron$30 seconds$cron$, $cron$select public.marketplace_poll_tick()$cron$);
select cron.schedule($cron$print-watch$cron$, $cron$* * * * *$cron$, $cron$select public.print_watch_tick()$cron$);
select cron.schedule($cron$queue-housekeeping$cron$, $cron$10 7 * * *$cron$, $cron$select public.queue_housekeeping()$cron$);
select cron.schedule($cron$reservations-forget$cron$, $cron$20 7 * * *$cron$, $cron$select public.reservations_forget()$cron$);
select cron.schedule($cron$salao-tick$cron$, $cron$*/5 * * * *$cron$, $cron$select public.salao_tick()$cron$);
select cron.schedule($cron$staff-pin-attempts-cleanup$cron$, $cron$15 7 * * *$cron$, $cron$
      delete from public.staff_pin_attempts where updated_at < now() - interval '30 days';
    $cron$);
select cron.schedule($cron$stock-digest$cron$, $cron$0 11 * * *$cron$, $cron$select public.stock_digest_tick()$cron$);
select cron.schedule($cron$stock-reconcile$cron$, $cron$*/5 * * * *$cron$, $cron$select public.reconcile_stock_orders()$cron$);
select cron.schedule($cron$tef-sweep$cron$, $cron$* * * * *$cron$, $cron$select public.tef_sweep_tick()$cron$);
select cron.schedule($cron$whatsapp-outbox$cron$, $cron$* * * * *$cron$, $cron$select public.whatsapp_outbox_tick()$cron$);
select cron.schedule($cron$whatsapp-retention$cron$, $cron$30 6 * * *$cron$, $cron$select public.whatsapp_retention()$cron$);
update cron.job set active = false;
