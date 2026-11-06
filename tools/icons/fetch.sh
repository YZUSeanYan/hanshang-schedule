#!/bin/bash
BASE="https://fonts.gstatic.com/s/i/short-term/release"
OUT_ICONS="calendar_month download person more_vert close chevron_left chevron_right add settings share schedule notifications notifications_active mail smartphone info logout sync event_available people_alt auto_awesome add_photo_alternate table_chart vpn_lock key pin group menu_book edit delete check my_location calendar_add_on coffee error refresh link send search hourglass_top password content_copy open_in_new school privacy_tip playlist_add cloud_off delete_sweep arrow_back notifications_none image"
for name in $OUT_ICONS; do
  curl -sfL --max-time 20 "$BASE/materialsymbolsoutlined/$name/default/24px.svg" -o "out_$name.svg" || echo "FAIL outlined $name"
done
for name in calendar_month download person; do
  curl -sfL --max-time 20 "$BASE/materialsymbolsoutlined/$name/fill1/24px.svg" -o "fill_$name.svg" || echo "FAIL fill $name"
done
echo done
