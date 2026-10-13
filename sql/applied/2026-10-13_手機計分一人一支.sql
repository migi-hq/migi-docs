-- ============================================================
-- 手機計分一人一支：配對新的永久手機 ⇒ 他名下其他永久的手機自動停用
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「手機計分最多一支，不能重複比較好吧？」（後台看到兩張「本狩 岡五郎」）
--   多支的問題：後台好幾張同名卡片分不出哪支在用；舊手機忘了停用，掉了或給了別人還能替他計分。
--
-- 規則：
--   · 用永久的碼配對（成桌卡片、會員 App、後台發的；table_phone_codes.session_id 是 null）⇒
--     他名下其他永久的手機停用（is_active = false、revoked_at）；舊手機正坐在牌局上的話，座位直接讓給新手機
--   · 平板發的「只限這一場」碼（session_id 有值）不動他的永久手機 —— 那支收桌就失效
--   · 已經有多支的人一次清掉：留最近用過的那支，其餘停用（2026-10-13 只有創辦人：中午測試配的那支）
--     ⚠ 正坐在開著的牌局上的不動
--
-- 只在 tbl_phone_redeem_tx「把碼標成用過」那一行後面插一段（線上比對過剛好一處），其餘一個字都不改；對不上就整份不執行。
-- ============================================================

do $$
declare
  v_def text := replace(pg_get_functiondef('public.tbl_phone_redeem_tx'::regproc), E'\r\n', E'\n');
  v_old text := $o$  update table_phone_codes set used_at = now(), used_by_device = d.id where id = c.id;$o$;
  v_new text := $n$  update table_phone_codes set used_at = now(), used_by_device = d.id where id = c.id;

  /* 📱 一人一支（2026-10-13 使用者）：永久配對 ⇒ 他名下其他永久的手機停用；
     舊手機正坐在牌局上的座位讓給新手機（同一場裡新手機已經綁了別的座位就不動，免得撞唯一索引） */
  if c.session_id is null then
    perform public._tbl_ping(x.session_id)
       from (select distinct sp.session_id from session_players sp
               join table_devices o on o.id = sp.device_id
              where sp.left_at is null and sp.member_id = c.member_id
                and o.kind = 'phone' and o.member_id = c.member_id and o.id <> d.id
                and o.bound_session_id is null and o.is_active) x;
    update session_players sp set device_id = d.id
     where sp.left_at is null and sp.member_id = c.member_id
       and sp.device_id in (select o.id from table_devices o
                             where o.kind = 'phone' and o.member_id = c.member_id and o.id <> d.id
                               and o.bound_session_id is null and o.is_active)
       and not exists (select 1 from session_players x where x.session_id = sp.session_id and x.device_id = d.id);
    update table_devices set is_active = false, revoked_at = now()
     where kind = 'phone' and member_id = c.member_id and id <> d.id
       and bound_session_id is null and is_active and revoked_at is null;
  end if;$n$;
begin
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'tbl_phone_redeem_tx 對不上，整份不執行';   -- 守衛
  end if;
  execute replace(v_def, v_old, v_new);
end $$;

-- 已經有多支的人：留最近用過的那支，其餘停用（正坐在開著的牌局上的不動）
update public.table_devices t set is_active = false, revoked_at = now()
 where t.kind = 'phone' and t.is_active and t.revoked_at is null and t.bound_session_id is null
   and exists (select 1 from public.table_devices n
                where n.member_id = t.member_id and n.kind = 'phone' and n.is_active and n.revoked_at is null
                  and n.bound_session_id is null and n.id <> t.id
                  and coalesce(n.last_seen_at, n.created_at) > coalesce(t.last_seen_at, t.created_at))
   and not exists (select 1 from public.session_players sp join public.table_sessions ts on ts.id = sp.session_id
                    where sp.device_id = t.id and sp.left_at is null and ts.status = 'open');


-- ============================================================
-- 驗證（單一 SELECT，不 raise）
--   ① 配對函式版本數 1、有一人一支那一段（舊版會紅 —— 正對照）
--   ② 現在沒有人有兩支以上還能用的永久手機
--   ③ ℹ 這次停用了幾支（剛剛 revoked_at 的手機）
-- ============================================================
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where proname = 'tbl_phone_redeem_tx' and pronamespace = 'public'::regnamespace) = 1
        and (select pg_get_functiondef('public.tbl_phone_redeem_tx'::regproc) ~ '一人一支')
       then '① ✅ 配對時會停用他其他的永久手機' else '① 🔴 配對函式沒改到' end,
  case when not exists (select 1 from table_devices where kind = 'phone' and is_active and revoked_at is null and bound_session_id is null
                         group by member_id having count(*) > 1)
       then '② ✅ 沒有人有兩支以上的永久手機' else '② 🔴 還有人有兩支以上' end,
  '③ ℹ 這次停用：' || coalesce((select string_agg(m.display_name || '（' || to_char(d.created_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI') || ' 配對）', '、')
                                  from table_devices d join members m on m.id = d.member_id
                                 where d.kind = 'phone' and d.revoked_at > now() - interval '1 minute'), '沒有')
) as "驗證";
