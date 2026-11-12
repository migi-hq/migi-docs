-- ════════════════════════════════════════════════════════════════════
-- 2026-11-12　線上開打：30 分鐘沒有任何動作就收掉（店裡計分板的維持 6 小時）
-- ════════════════════════════════════════════════════════════════════
-- 起因：11-11 20:21 那一場線上開打（使用者 ＋ 三隻電腦小熊），21:41 之後大家都離開，
--   但 sweep_friendly_tx 第 ③ 段要「6 小時沒有任何一局」才收 ⇒ 那段時間他被算成
--   「還在好友練習賽裡」，報配桌、開新的一場都會被 _check_join_conflict 擋下。
--   6 小時是替店裡計分板訂的（人在桌邊可能休息很久），線上開打大家一離開就不會再動。
--
-- 怎麼判斷「還有沒有人」：
--   online_hands.updated_at 每一個動作都會更新，包括電腦代打 ——
--   而電腦代打只在有人的手機開著、去叫後端時才會發生 ⇒ 它就是「最後一次有人開著」。
--   ⚠ 不能用「最後一次真人出手」：開著電腦代打在旁邊看的人（那一場使用者只出手 1 次、
--     代打 844 次）會被誤收。online_seats.last_seen_at 也一樣只在真人出手時更新。
--
-- 收法跟原本第 ③ 段一樣（只改門檻與通知的字）：
--   打完 1 將以上 ⇒ 照打完的將結算再收；一將都沒打完 ⇒ 作廢、通知。
--
-- 動到的東西：
--   🆕 _friendly_last_active(game)   最後一次有動靜的時間（計分板的局、線上的動作、開打時間取最晚）
--   🆕 _friendly_idle_limit(mode)    online 30 分鐘、其餘 6 小時
--   ✏️ sweep_friendly_tx()           第 ③ 段改用上面兩支；①② 一字不改。簽名不變 ⇒ CREATE OR REPLACE，授權不會掉
--   兩支新的只給內部用：09-29 起新建的函式預設全關，不另外 grant
-- ════════════════════════════════════════════════════════════════════

create or replace function public._friendly_last_active(p_game uuid)
returns timestamptz
language sql stable security definer set search_path to 'public'
as $$
  -- greatest 會略過 null：沒有線上動作的（計分板）就跟原本的算法一模一樣
  select greatest(
           g.started_at,
           (select max(coalesce(h.confirmed_at, h.created_at)) from hands h where h.session_id = g.session_id),
           (select max(oh.updated_at) from online_hands oh where oh.session_id = g.session_id))
    from friendly_games g where g.id = p_game;
$$;

create or replace function public._friendly_idle_limit(p_mode text)
returns interval
language sql immutable
as $$
  select case when p_mode = 'online' then interval '30 minutes' else interval '6 hours' end;
$$;

create or replace function public.sweep_friendly_tx()
returns integer
language plpgsql security definer set search_path to 'public'
as $function$
declare g record; r record; n int := 0; v jsonb; v_last timestamptz; v_text text;
begin
  -- ① 過了最晚開打時間還沒湊滿 ⇒ 取消、通知
  for g in select * from friendly_games where status = 'waiting' and play_at < now() for update skip locked loop
    for r in select member_id from friendly_game_players where game_id = g.id and left_at is null loop
      insert into app_notifications (org_id, member_id, type, ref_id, payload)
      values (g.org_id, r.member_id, 'friendly_out', g.id,
              jsonb_build_object('text', '好友練習賽到了最晚開打時間還沒湊滿四人，已自動取消', 'game_id', g.id));
    end loop;
    update friendly_game_players set left_at = now(), leave_reason = 'expired' where game_id = g.id and left_at is null;
    update friendly_games set status = 'cancelled', cancel_reason = 'expired', ended_at = now(), updated_at = now()
     where id = g.id;
    n := n + 1;
  end loop;

  -- ② 打完 15 分鐘 ⇒ 收掉場次（這 15 分鐘讓手機看牌局結束卡）
  for g in select fg.* from friendly_games fg join table_sessions ts on ts.id = fg.session_id
            where fg.status = 'finished' and ts.status = 'open' and fg.ended_at < now() - interval '15 minutes' loop
    perform public._friendly_close(g.session_id);
    n := n + 1;
  end loop;

  -- ③ 太久沒有動靜 ⇒ 打完 1 將以上照打完的將結算再收；一將都沒打完 ⇒ 作廢、通知
  --    ★ 2026-11-12：線上開打 30 分鐘（電腦代打也算動靜）、店裡計分板維持 6 小時
  for g in select * from friendly_games where status = 'playing' for update skip locked loop
    v_last := public._friendly_last_active(g.id);
    if coalesce(v_last, g.started_at) >= now() - public._friendly_idle_limit(g.play_mode) then continue; end if;

    v := null;
    if exists (select 1 from session_rounds where session_id = g.session_id and status = 'finished') then
      begin
        v := public._score_settle_tx(g.session_id);
      exception when others then v := null;
      end;
    end if;
    if coalesce((v ->> 'ok')::boolean, false) then
      update friendly_games set status = 'finished', ended_at = coalesce(ended_at, now()), updated_at = now()
       where id = g.id and status = 'playing';
      perform public._friendly_close(g.session_id);
    else
      v_text := case when g.play_mode = 'online'
                     then '好友練習賽 30 分鐘沒有人在線上，已自動結束（沒有打完一將，成績不算）'
                     else '好友練習賽 6 小時沒有記分，已自動結束（沒有打完一將，成績不算）' end;
      for r in select member_id from friendly_game_players where game_id = g.id and left_at is null loop
        insert into app_notifications (org_id, member_id, type, ref_id, payload)
        values (g.org_id, r.member_id, 'friendly_out', g.id, jsonb_build_object('text', v_text, 'game_id', g.id));
      end loop;
      perform public._friendly_close(g.session_id, true);
      update friendly_game_players set left_at = now(), leave_reason = 'expired' where game_id = g.id and left_at is null;
      update friendly_games set status = 'cancelled', cancel_reason = 'stale', ended_at = now(), updated_at = now()
       where id = g.id;
    end if;
    n := n + 1;
  end loop;
  return n;
end $function$;

-- 兩支新的：預設全關，這裡明寫一次，免得哪天預設被改回全開（錯誤儀表 ⑱ 也在盯）
revoke execute on function public._friendly_last_active(uuid) from public, anon, authenticated;
revoke execute on function public._friendly_idle_limit(text)  from public, anon, authenticated;

-- ── 行為測試：拿卡住的那一場（e8fb4e41…）當樣本，測完退回 ──────────────────────
-- ⚠ 這兩個 raise 都在「自己接住的小區塊」裡：只退回那一小段（樣本），上面建的函式照樣留下。
--   硬規則 1.8 怕的是「沒接住的 raise 把整份退回」，這裡不是那一種。
--   放在這一份而不是另開 checks 檔，是因為排程 5 分鐘內就會把那一場真的收掉，之後就沒有樣本了。
do $$
declare v_gid uuid := 'e8fb4e41-06a2-4be1-add8-99cbd9b668df'; v_sid uuid; v_st text;
begin
  select session_id, status into v_sid, v_st from friendly_games where id = v_gid;
  if v_sid is null or v_st <> 'playing' then
    perform set_config('migi.t1', '⚪ 負對照測不了：那一場已經不是打牌中（可能排程先收掉了）', true);
    perform set_config('migi.t2', '⚪ 正對照測不了：同上（跑完之後查一下它是不是 cancelled/stale）', true);
    return;
  end if;

  -- 負對照：把它的線上動作時間改成「剛剛」⇒ 不可以被收掉
  begin
    update online_hands set updated_at = now() where session_id = v_sid;
    perform public.sweep_friendly_tx();
    select status into v_st from friendly_games where id = v_gid;
    raise exception 'migi_rollback:%', v_st;
  exception when others then
    perform set_config('migi.t1',
      case when sqlerrm = 'migi_rollback:playing' then '✅ 負對照：剛剛還有動作的線上牌局沒有被收掉'
           else '🔴 負對照失敗：' || sqlerrm end, true);
  end;

  -- 正對照：照實際時間（21:41 之後沒動）⇒ 要被收掉、一將都沒打完所以是作廢
  begin
    perform public.sweep_friendly_tx();
    select status || '/' || coalesce(cancel_reason, '') into v_st from friendly_games where id = v_gid;
    raise exception 'migi_rollback:%', v_st;
  exception when others then
    perform set_config('migi.t2',
      case when sqlerrm = 'migi_rollback:cancelled/stale' then '✅ 正對照：21:41 之後沒人在的那一場會被收掉（測完已退回，交給排程真的收）'
           else '🔴 正對照失敗：' || sqlerrm end, true);
  end;
end $$;

-- ── 驗證（單一 SELECT）────────────────────────────────────────────
select concat_ws(E'\n',
  -- ① 函式各只有一個版本，排程那支有用到新的兩支
  (select case when count(*) = 1 and bool_and(pg_get_functiondef(p.oid) ~ '_friendly_last_active\(' and pg_get_functiondef(p.oid) ~ '_friendly_idle_limit\(')
               then '✅ ① sweep_friendly_tx 一個版本，第 ③ 段已改用新的判斷'
               else '🔴 ① sweep_friendly_tx 版本數 ' || count(*) || ' 或沒有用到新的兩支' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'sweep_friendly_tx'),

  -- ② 新的兩支沒有開給前端（PUBLIC／anon／authenticated 都沒有）
  (select case when count(*) = 2 and bool_and(
                 p.proacl is not null
                 and not exists (select 1 from aclexplode(p.proacl) a
                                  where a.privilege_type = 'EXECUTE'
                                    and (a.grantee = 0 or a.grantee in ('anon'::regrole::oid, 'authenticated'::regrole::oid))))
               then '✅ ② 兩支新函式前端叫不到'
               else '🔴 ② 新函式的授權不對（或沒建成）' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('_friendly_last_active', '_friendly_idle_limit')),

  -- ③ 排程那支的授權沒被動到（CREATE OR REPLACE 不會丟授權；它本來就只有 postgres 與 service_role）
  (select case when not exists (select 1 from aclexplode(p.proacl) a
                                 where a.privilege_type = 'EXECUTE'
                                   and (a.grantee = 0 or a.grantee in ('anon'::regrole::oid, 'authenticated'::regrole::oid)))
               then '✅ ③ sweep_friendly_tx 仍然只有內部叫得到'
               else '🔴 ③ sweep_friendly_tx 被開給前端了' end
     from pg_proc p where p.oid = 'public.sweep_friendly_tx()'::regprocedure),

  -- ④ 門檻
  case when public._friendly_idle_limit('online') = interval '30 minutes'
        and public._friendly_idle_limit('scoreboard') = interval '6 hours'
       then '✅ ④ 線上 30 分鐘、計分板 6 小時'
       else '🔴 ④ 門檻不對：線上 ' || public._friendly_idle_limit('online') || '、計分板 ' || public._friendly_idle_limit('scoreboard') end,

  -- ⑤ 計分板的牌局：新算法跟原本一模一樣（全部歷史逐場比）；線上的：新算法不會比原本早
  (select case when count(*) filter (where g.play_mode <> 'online' and n.v is distinct from o.v) = 0
                and count(*) filter (where g.play_mode = 'online' and n.v < o.v) = 0
               then '✅ ⑤ 逐場比對 ' || count(*) || ' 場：計分板的跟原本一樣、線上的不會比原本早'
               else '🔴 ⑤ 有 ' || (count(*) filter (where g.play_mode <> 'online' and n.v is distinct from o.v)) || ' 場計分板牌局的時間跟原本不同' end
     from friendly_games g
     cross join lateral (select public._friendly_last_active(g.id) as v) n
     cross join lateral (select greatest(g.started_at, max(coalesce(h.confirmed_at, h.created_at))) as v
                           from hands h where h.session_id = g.session_id) o),

  -- ⑥ 現在打牌中的每一場：最後動靜、門檻、會不會被收
  coalesce((select string_agg('ℹ️ ⑥ 打牌中 ' || left(g.id::text, 8) || '（' || g.play_mode || '）最後動靜 '
                  || coalesce(to_char(public._friendly_last_active(g.id) at time zone 'Asia/Taipei', 'MM-DD HH24:MI'), '—')
                  || case when coalesce(public._friendly_last_active(g.id), g.started_at) < now() - public._friendly_idle_limit(g.play_mode)
                          then ' ⇒ 下一輪排程（5 分鐘內）會收掉' else ' ⇒ 還在時間內，不收' end, E'\n')
              from friendly_games g where g.status = 'playing'),
           'ℹ️ ⑥ 現在沒有打牌中的好友練習賽'),

  -- ⑦⑧ 行為測試
  coalesce(nullif(current_setting('migi.t1', true), ''), '🔴 ⑦ 負對照沒有跑到'),
  coalesce(nullif(current_setting('migi.t2', true), ''), '🔴 ⑧ 正對照沒有跑到'),

  -- ⑨ 排程還在跑
  (select case when count(*) = 1 and bool_and(j.active) then '✅ ⑨ 排程 friendly-sweep 每 5 分鐘在跑'
               else '🔴 ⑨ 排程 friendly-sweep 不在或停了' end
     from cron.job j where j.jobname = 'friendly-sweep')
) as "驗證";
