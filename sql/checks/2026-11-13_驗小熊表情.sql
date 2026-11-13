/* 驗「線上好友房：小熊表情」的行為（2026-11-13）—— 唯讀檢查：整段在交易裡造樣本，最後故意 raise 回滾，什麼都不會留下。
   先跑過 sql/pending/2026-11-13_線上好友房_小熊表情.sql 才有意義。

   樣本：拿最近一場已收桌的線上牌局，在交易裡把座位 1 改回「還坐著」（收桌時每一家都寫了 left_at）。
   ⚠ 找不到樣本要出聲（硬規則 3.57），不要安靜跳過 */
do $$
declare v_sid uuid; v_msg text := ''; v_ok int := 0; r jsonb; c jsonb;
begin
  select g.session_id into v_sid from friendly_games g
    where g.play_mode = 'online' and exists (select 1 from session_players sp where sp.session_id = g.session_id and sp.seat = 1)
    order by g.created_at desc limit 1;
  if v_sid is null then
    perform set_config('migi.emote_t', '⚪ 找不到有座位 1 的線上牌局，這份測不了', true);
    return;
  end if;
  -- 🔴 造樣本的這兩行一定要在下面那個 begin…exception 裡面：回滾只退得掉那一段，寫在外面會真的留下來
  begin
    update session_players set left_at = null where session_id = v_sid and seat = 1;
    update session_players set left_at = coalesce(left_at, now()) where session_id = v_sid and seat = 2;   -- 座位 2 確定是「離開了」

    -- ① 坐著的人送一個 ⇒ ok
    r := public.online_emote_tx(v_sid, 1::smallint, 'nice');
    if r->>'ok' = 'true' then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ① 坐著的人送得出去';
    else v_msg := v_msg || E'\n🔴 ① 送不出去：' || r::text; end if;

    -- ② _online_ctx 讀得回來（presence 的座位 1）
    c := public._online_ctx(v_sid);
    if c->'presence'->'1'->>'emote' = 'nice' and c->'presence'->'1'->>'emote_at' is not null
      then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ② _online_ctx 的 presence 讀得到剛送的表情';
      else v_msg := v_msg || E'\n🔴 ② 讀不到：' || coalesce((c->'presence')::text, 'null'); end if;

    -- ③ 2 秒內再送 ⇒ too_fast，而且沒有蓋掉上一個
    r := public.online_emote_tx(v_sid, 1::smallint, 'thanks');
    if r->>'reason' = 'too_fast' and (select emote from online_seats where session_id = v_sid and seat = 1) = 'nice'
      then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ③ 2 秒內再送被擋（too_fast），上一個沒被蓋掉';
      else v_msg := v_msg || E'\n🔴 ③ 沒擋住：' || r::text; end if;

    -- ④ 正對照：把上一次的時間往前推 3 秒，再送就要成功（不然 ③ 的「擋住」可能只是函式永遠不給送）
    update online_seats set emote_at = now() - interval '3 seconds' where session_id = v_sid and seat = 1;
    r := public.online_emote_tx(v_sid, 1::smallint, 'thanks');
    if r->>'ok' = 'true' and (select emote from online_seats where session_id = v_sid and seat = 1) = 'thanks'
      then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ④ 過了 2 秒照樣送得出去（正對照）';
      else v_msg := v_msg || E'\n🔴 ④ 過了 2 秒還是送不出去：' || r::text; end if;

    -- ⑤ 代碼格式不對 ⇒ bad_emote
    r := public.online_emote_tx(v_sid, 1::smallint, 'Bad!');
    if r->>'reason' = 'bad_emote' then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ⑤ 格式不對的代碼被擋（bad_emote）';
    else v_msg := v_msg || E'\n🔴 ⑤ 沒擋住：' || r::text; end if;

    -- ⑥ 已經離開的座位 ⇒ bad_seat
    r := public.online_emote_tx(v_sid, 2::smallint, 'nice');
    if r->>'reason' = 'bad_seat' then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ⑥ 已經離開的座位送不出去（bad_seat）';
    else v_msg := v_msg || E'\n🔴 ⑥ 沒擋住：' || r::text; end if;

    raise exception 'migi_rollback';
  exception when others then
    perform set_config('migi.emote_t', case when sqlerrm = 'migi_rollback' then v_ok || ' / 6' || v_msg else '🔴 出錯：' || sqlerrm || v_msg end, true);
  end;
end $$;
select coalesce(nullif(current_setting('migi.emote_t', true), ''), '🔴 沒有訊息') as "行為測試";
