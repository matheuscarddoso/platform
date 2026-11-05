-- Storage RLS policies from Supabase Cloud (the managed storage schema is not in
-- the schema dump). Public read for the three public buckets.
drop policy if exists "Public can view menu item images" on storage.objects;
drop policy if exists "Public can view restaurant logos" on storage.objects;
drop policy if exists "Public can view story videos" on storage.objects;
create policy "Public can view menu item images" on storage.objects for select to public using (bucket_id = 'menu-item-images'::text);
create policy "Public can view restaurant logos" on storage.objects for select to public using (bucket_id = 'restaurant-logos'::text);
create policy "Public can view story videos" on storage.objects for select to public using (bucket_id = 'menu-item-videos'::text);
