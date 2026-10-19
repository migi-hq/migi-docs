-- ════════════════════════════════════════════════════════════════════
-- 換人上桌的代碼也能用來換手機（2026-10-20 使用者選 B）
--
-- 起因：妮妮 10/17、10/19 在計分板上按「換一支手機」拿了 18 組代碼，一組都沒用成。
--   那顆按鈕給的是「換人上桌」代碼（2026-10-15），只能在「另一個人已經配好的手機」上
--   從「接手別人的位置」輸入；她的新手機還沒配對，只看得到「輸入配對碼」，輸入就是「配對碼不對」。
--
-- 改成（tbl_phone_redeem_tx ＝ 新手機的「輸入配對碼」）：查不到配對碼時，再查換人上桌代碼 ——
--   · 還沒配對的手機（或本來就是同一個人的手機）輸入 ⇒ 當成「同一個人換手機」：
--       這支手機變成他的手機計分板（永久，不限這一場）、
--       他那個位置交給這支手機（代碼是平板給的也一樣，平板變成沒有選人）、
--       他名下其他的手機停用（一人一支，同 2026-10-13）
--   · 已經是別人的手機在這一頁輸入 ⇒ 不換，回一句「請在『接手別人的位置』輸入」（換人上桌照舊走 tbl_swap_redeem_tx）
--   使用者拍板：不問「你是某某嗎」—— 在新手機上輸入這組代碼，就是本人換手機。
--
-- 紀錄：session_seat_swaps 那一列記 used_at、to_member_id ＝ 他自己（from ＝ to 就是換手機，不是換人）、to_device_id ＝ 新手機。
-- 簽名不變 ⇒ CREATE OR REPLACE，授權不會掉。
-- 行為測試：sql/checks/2026-10-20_驗換人上桌代碼換手機.sql
-- ════════════════════════════════════════════════════════════════════

create or replace function public.tbl_phone_redeem_tx(p_code text, p_token text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_code text := regexp_replace(coalesce(p_code, ''), '\D', '', 'g');
  c public.table_phone_codes; s public.session_seat_swaps; d public.table_devices; v_row public.session_players;
  v_token text; v_name text; v_member uuid; v_org uuid; v_bound uuid; v_swap boolean := false;
begin
  if (select count(*) from table_phone_code_fails where at > now() - interval '10 minutes') >= 60 then
    return jsonb_build_object('ok', false, 'reason', 'busy', 'message', '輸入錯誤太多次，請 10 分鐘後再試');
  end if;
  if length(v_code) <> 6 then
    return jsonb_build_object('ok', false, 'reason', 'bad_code', 'message', '配對碼是 6 位數字');
  end if;

  /* 這支手機已經配對過的話先認出來 */
  if p_token is not null and length(p_token) >= 32 then
    select * into d from table_devices
     where token_hash = public._tbl_hash(p_token) and is_active and kind = 'phone';
  end if;

  select * into c from table_phone_codes
   where code = v_code and used_at is null and expires_at > now()
   order by created_at desc limit 1
   for update;

  if found then
    if c.session_id is not null and not exists (
         select 1 from table_sessions where id = c.session_id and status = 'open' and deleted_at is null) then
      return jsonb_build_object('ok', false, 'reason', 'session_closed', 'message', '這一場已經結束了');
    end if;
    v_member := c.member_id; v_org := c.org_id; v_bound := c.session_id;
  else
    /* 🆕 換手機（2026-10-20）：不是配對碼，看是不是換人上桌的代碼 */
    select * into s from session_seat_swaps
     where code = v_code and used_at is null and expires_at > now()
     order by created_at desc limit 1
     for update;
    if not found then
      insert into table_phone_code_fails default values;
      return jsonb_build_object('ok', false, 'reason', 'bad_code', 'message', '配對碼不對，或已經用過、過期了');
    end if;
    if d.id is not null and d.member_id is distinct from s.from_member_id then
      return jsonb_build_object('ok', false, 'reason', 'use_takeover',
        'message', '這是換人上桌的代碼，請在「接手別人的位置」輸入');
    end if;
    if exists (select 1 from members where id = s.from_member_id and hidden_at is not null) then
      return jsonb_build_object('ok', false, 'reason', 'hidden', 'message', '這個帳號已隱藏，請洽櫃檯');
    end if;
    v_member := s.from_member_id; v_org := s.org_id; v_bound := null; v_swap := true;
  end if;

  /* 這支手機已經配對過 ⇒ 沿用同一個憑證，改成新主人（換手機時本來就是同一個人） */
  if d.id is not null then
    update table_devices set member_id = v_member, bound_session_id = v_bound, org_id = v_org,
                             last_seen_at = now()
     where id = d.id;
    v_token := p_token;
  else
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    insert into table_devices (org_id, kind, member_id, bound_session_id, label, token_hash, last_seen_at)
    values (v_org, 'phone', v_member, v_bound, '手機', public._tbl_hash(v_token), now())
    returning * into d;
  end if;

  if v_swap then
    select * into v_row from session_players where id = s.player_row_id;
    update session_seat_swaps
       set used_at = now(), to_member_id = v_member, to_device_id = d.id, before_row = to_jsonb(v_row)
     where id = s.id;
    -- 同一個位置還沒用掉的其他碼作廢
    update session_seat_swaps set expires_at = now()
     where player_row_id = s.player_row_id and used_at is null and expires_at > now();
    -- 他的位置交給這支手機（那一場還開著、位置還是他的才搬；代碼是平板給的也一樣）
    if v_row.member_id = v_member and v_row.left_at is null
       and exists (select 1 from table_sessions where id = v_row.session_id and status = 'open' and deleted_at is null) then
      update session_players set device_id = null
       where session_id = v_row.session_id and device_id = d.id and id <> v_row.id;
      update session_players set device_id = d.id where id = v_row.id;
      perform public._tbl_ping(v_row.session_id);
    end if;
  else
    update table_phone_codes set used_at = now(), used_by_device = d.id where id = c.id;
  end if;

  /* 📱 一人一支（2026-10-13 使用者）：永久配對 ⇒ 他名下其他永久的手機停用；
     舊手機正坐在牌局上的座位讓給新手機（同一場裡新手機已經綁了別的座位就不動，免得撞唯一索引） */
  if v_bound is null then
    perform public._tbl_ping(x.session_id)
       from (select distinct sp.session_id from session_players sp
               join table_devices o on o.id = sp.device_id
              where sp.left_at is null and sp.member_id = v_member
                and o.kind = 'phone' and o.member_id = v_member and o.id <> d.id
                and o.bound_session_id is null and o.is_active) x;
    update session_players sp set device_id = d.id
     where sp.left_at is null and sp.member_id = v_member
       and sp.device_id in (select o.id from table_devices o
                             where o.kind = 'phone' and o.member_id = v_member and o.id <> d.id
                               and o.bound_session_id is null and o.is_active)
       and not exists (select 1 from session_players x where x.session_id = sp.session_id and x.device_id = d.id);
    update table_devices set is_active = false, revoked_at = now()
     where kind = 'phone' and member_id = v_member and id <> d.id
       and bound_session_id is null and is_active and revoked_at is null;
  end if;

  /* 平板發的碼：兌換的那一刻直接接手那個位置（原本那台平板變成沒有位置 ⇒ 觀看） */
  if v_bound is not null then
    update session_players set device_id = null
     where session_id = v_bound and device_id = d.id and member_id <> v_member;
    update session_players set device_id = d.id
     where session_id = v_bound and member_id = v_member and left_at is null;
    perform public._tbl_ping(v_bound);
  end if;

  select display_name into v_name from members where id = v_member;
  return jsonb_build_object('ok', true, 'token', v_token, 'name', v_name,
    'this_game_only', v_bound is not null, 'changed_phone', v_swap);
end $function$;

-- 驗證（單一 SELECT）：版本 1 個、認得換人上桌代碼、別人的手機會被導去接手、授權沒掉
select
  case when (select count(*) from pg_proc where proname = 'tbl_phone_redeem_tx' and pronamespace = 'public'::regnamespace) = 1
       then '✅ 1 個版本' else '🔴 版本數不對' end as "①",
  case when pg_get_functiondef(p.oid) ~ 'from session_seat_swaps' and pg_get_functiondef(p.oid) ~ 'changed_phone'
       then '✅ 查不到配對碼時會查換人上桌代碼' else '🔴 沒有換手機那一段' end as "②",
  case when pg_get_functiondef(p.oid) ~ 'use_takeover' then '✅ 別人的手機輸入會被導去「接手別人的位置」' else '🔴 少了 use_takeover' end as "③",
  case when pg_get_functiondef(p.oid) ~ 'table_phone_code_fails' then '✅ 輸錯次數限制還在' else '🔴 輸錯限制不見了' end as "④",
  case when has_function_privilege('anon', p.oid, 'execute') and has_function_privilege('authenticated', p.oid, 'execute')
       then '✅ 手機叫得到（anon 與 authenticated）' else '🔴 授權掉了' end as "⑤"
from pg_proc p
where p.proname = 'tbl_phone_redeem_tx' and p.pronamespace = 'public'::regnamespace;
