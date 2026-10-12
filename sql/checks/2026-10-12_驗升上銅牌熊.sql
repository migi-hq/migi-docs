-- ============================================================================
-- 2026-10-12  行為測試：段位變動時「升上銅牌熊」有沒有照規則解鎖
-- 先跑 sql/pending/2026-10-12_成就新增升上銅牌熊.sql，再跑這一份。
-- 全部在交易裡造樣本，最後回滾（一筆都不會留下）。
--   ① 沒有段位 → 銅牌熊 III        要解鎖 rank_18
--   ② 沒有段位 → 銀牌熊 III        一次跨兩階：rank_18 與 rank_02 都要解鎖
--   ③ 銅牌熊 IV → 銅牌熊 III（負對照） 同階升級，rank_18 不可以被解鎖
-- ============================================================================
do $$
declare
  v_mem uuid; v_a18 uuid; v_a02 uuid; v_msg text := '';
begin
  begin
    select id into v_mem from public.members
     where is_test and deleted_at is null and rank is not null
     order by created_at limit 1;
    select id into v_a18 from public.achievements where code = 'rank_18' and deleted_at is null;
    select id into v_a02 from public.achievements where code = 'rank_02' and deleted_at is null;
    if v_mem is null then raise exception 'migi_nosample:找不到有段位的測試帳號'; end if;
    if v_a18 is null then raise exception 'migi_nosample:rank_18 不存在，先跑 pending 那份'; end if;

    -- ①
    delete from public.member_achievements where member_id = v_mem and achievement_id = v_a18;
    update public.members set rank = null where id = v_mem;
    update public.members set rank = '銅牌熊 III' where id = v_mem;
    v_msg := v_msg || case when exists (select 1 from public.member_achievements
                                         where member_id = v_mem and achievement_id = v_a18 and status = 'unlocked')
                           then '✅ ① 沒有段位 → 銅牌熊：解鎖升上銅牌熊'
                           else '🔴 ① 沒有段位 → 銅牌熊：沒有解鎖' end;

    -- ②
    delete from public.member_achievements where member_id = v_mem and achievement_id in (v_a18, v_a02);
    update public.members set rank = null where id = v_mem;
    update public.members set rank = '銀牌熊 III' where id = v_mem;
    v_msg := v_msg || E'\n' || case when (select count(*) from public.member_achievements
                                           where member_id = v_mem and achievement_id in (v_a18, v_a02) and status = 'unlocked') = 2
                           then '✅ ② 沒有段位 → 銀牌熊：銅牌、銀牌兩枚都解鎖'
                           else '🔴 ② 沒有段位 → 銀牌熊：解鎖 ' || (select count(*) from public.member_achievements
                                           where member_id = v_mem and achievement_id in (v_a18, v_a02) and status = 'unlocked') || ' 枚（應為 2）' end;

    -- ③ 負對照
    update public.members set rank = '銅牌熊 IV' where id = v_mem;
    delete from public.member_achievements where member_id = v_mem and achievement_id = v_a18;
    update public.members set rank = '銅牌熊 III' where id = v_mem;
    v_msg := v_msg || E'\n' || case when not exists (select 1 from public.member_achievements
                                         where member_id = v_mem and achievement_id = v_a18 and status = 'unlocked')
                           then '✅ ③ 銅牌熊 IV → III：沒有誤發升上銅牌熊'
                           else '🔴 ③ 同階升級也解鎖了升上銅牌熊' end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.t', v_msg, true);
    elsif sqlerrm like 'migi_nosample:%' then
      perform set_config('migi.t', '⚪ ' || substr(sqlerrm, 15), true);
    else
      perform set_config('migi.t', coalesce(nullif(v_msg, '') || E'\n', '') || '🔴 中途出錯：' || sqlerrm, true);
    end if;
  end;
end $$;
select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "行為測試";
