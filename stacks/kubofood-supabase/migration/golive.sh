#!/usr/bin/env bash
# After cutover.sh: point the app's runtime env at the self-hosted API, then
# (once the CI deploy is live) activate the crons and smoke-test.
#   golive.sh env     -> sets NEXT_PUBLIC_SUPABASE_URL in Coolify; prints the new BUILD_ENV on stdout
#   golive.sh crons   -> activates pg_cron locally and checks the app answers
set -Eeuo pipefail
APP_UUID=441khsoyzvfgziplconlvss5
case "${1:-}" in
  env)
    docker exec coolify php artisan tinker --execute="
      \$a = \App\Models\Application::where('uuid', '$APP_UUID')->first();
      \$v = \$a->environment_variables()->where('key', 'NEXT_PUBLIC_SUPABASE_URL')->where('is_preview', false)->first();
      \$v->value = 'https://api.kubofood.app'; \$v->save();
      foreach (['GOOGLE_CLIENT_ID','GOOGLE_CLIENT_SECRET','GT_API_KEY','GT_PROJECT_ID','NEXTAUTH_URL','NEXT_PUBLIC_SECRET','NEXT_PUBLIC_STADIA_API_KEY','NEXT_PUBLIC_SUPABASE_ANON_KEY','NEXT_PUBLIC_SUPABASE_URL','NEXT_PUBLIC_WHATSAPP_BUSINESS_PHONE','SUPABASE_SERVICE_ROLE_KEY','WHATSAPP_ACCESS_TOKEN','WHATSAPP_ORDER_TEMPLATE_NAME','WHATSAPP_PHONE_NUMBER_ID'] as \$k) {
        \$e = \$a->environment_variables()->where('key', \$k)->where('is_preview', false)->first();
        if (\$e) echo \$k . \"='\" . \$e->value . \"'\" . PHP_EOL;
      }" 2>/dev/null | grep -E "^[A-Z_]+='"
    ;;
  crons)
    docker exec kubofood-sb-db psql -U supabase_admin -d postgres -Atc "update cron.job set active = true; select count(*) filter (where active) || '/' || count(*) || ' crons active' from cron.job"
    ;;
  *) echo "usage: golive.sh env|crons" >&2; exit 2 ;;
esac
