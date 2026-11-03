/* ============================================================
   創辦人測試按讚的小熊餅乾扣回 8 個（14 → 6）
   2026-11-03 · 寫入（migration）· 在 Supabase Dashboard 的 SQL Editor 執行

   ── 為什麼 ──
   創辦人（69016205-…）帳上 14 個餅乾全是按讚發的；其中 8 個是 10-07 測試「給同桌評價」時
   讚測試帳號拿到的（4 場，兩場是測試戰績工具造的假場次 d0000000-…-0002／0003）。
   使用者 11-03 拍板扣回；10-14、10-16 兩場真牌局讚真客人的 6 個保留。

   ── 做法 ──
   帳本只增不改：原本 8 筆不刪，補一筆 reason = 'admin'、qty = −8（冪等鍵固定，重跑不會扣兩次）。

   ── 順帶修一個觸發器 ──
   trg_snack_achievements 原本「帳本出現負數」就發 snack_consumed 事件 ⇒ 成就「餵一次小熊」（onboarding_17）會解鎖。
   總部扣回不是餵食 ⇒ 改成**只有 reason = 'feed' 的扣除才算**。不改的話這一筆會讓創辦人誤拿那枚成就。
   ============================================================ */

create or replace function public.trg_snack_achievements()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  begin
    if new.qty > 0 then
      perform public.fire_event_tx(new.member_id, 'snack_granted', 1, null,
                                   'snack:' || new.id::text);
    elsif new.qty < 0 and new.reason = 'feed' then
      -- 只有真的餵小熊才算吃掉；總部扣回（admin）等其他原因的扣除不發事件
      perform public.fire_event_tx(new.member_id, 'snack_consumed', 1, null,
                                   'snack:' || new.id::text);
    end if;
  exception when others then null;
  end;
  return null;
end $function$;

insert into public.snack_grants (org_id, member_id, kind, qty, reason, ref_id, idem_key)
select m.org_id, m.id, 'cookie', -8, 'admin', null, 'admin:2026-11-03:founder-test-likes'
  from public.members m
 where m.id = '69016205-afde-4036-95a6-5893c9d0e5fe'
on conflict (idem_key) do nothing;

/* ── 驗證（單一 SELECT，不 raise）──────────────────────────── */
select
  case when (select coalesce(sum(qty), 0) from public.snack_grants
              where member_id = '69016205-afde-4036-95a6-5893c9d0e5fe' and kind = 'cookie') = 6
       then '✅' else '🔴' end || ' ① 創辦人剩 6 個（'
    || (select coalesce(sum(qty), 0) from public.snack_grants
         where member_id = '69016205-afde-4036-95a6-5893c9d0e5fe' and kind = 'cookie') || '）'
  || E'\n' ||
  case when (select count(*) from public.snack_grants where idem_key = 'admin:2026-11-03:founder-test-likes') = 1
       then '✅' else '🔴' end || ' ② 扣回只有一筆'
  || E'\n' ||
  case when not exists (select 1 from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
                         where ma.member_id = '69016205-afde-4036-95a6-5893c9d0e5fe' and a.code = 'onboarding_17')
       then '✅' else '🔴' end || ' ③ 沒有誤解鎖「餵一次小熊」'
  || E'\n' ||
  case when pg_get_functiondef('public.trg_snack_achievements()'::regprocedure) ~ 'qty < 0 and new\.reason = ''feed'''
       then '✅' else '🔴' end || ' ④ 觸發器只認餵食的扣除'
  || E'\n' ||
  case when (select count(*) from public.snack_grants where member_id = '69016205-afde-4036-95a6-5893c9d0e5fe' and reason = 'like') = 14
       then '✅' else '🔴' end || ' ⑤ 原本 14 筆按讚紀錄沒動（負對照）'
  as "驗證";
