/* ============================================================
   會員等級的累積消費、報表的終身價值與新客分群：都從上線日（orgs.live_from）開始算
   （2026-11-03 使用者選 B：「封測的消費紀錄都不準確」）

   ── 會員等級 ─────────────────────────────────────────────────
   · 新增 _tier_spend(member, org)：累積消費的唯一一份算法
       ＝ 已付款訂單的 payable，只算 paid_at ≥ 上線日
       ⚠ 上線日還沒設（null）⇒ 一律 0 ⇒ 封測期間沒有人會升等
   · recalc_member_tier_tx（付款後由觸發器叫，真的升等）與 member_tier_progress_tx（App／POS 顯示還差多少）
     都改叫它 —— 在此之前兩支各寫一份 sum(payable)，改一邊忘另一邊的話「還差多少」會跟實際升等對不上
   · 已經升上去的等級不動（目前 158 位全是珍珠奶茶，沒有人升過）
   · member_tier_progress_tx 多回 counting_from（上線日；null ＝ 還沒開始累積）。
     ⚠ get_wallet_tx／pos_member_detail_tx 是挑固定欄位往外傳的，這個鍵目前沒有傳到前端：
       封測期間錢包頁本來就藏著，店員在 POS 看到「累積消費 $0」是對的

   ── 報表 ─────────────────────────────────────────────────────
   · _ops_report_core 的「客人終身價值」與「新客分群」只看上線日之後（上線日沒設 ⇒ 跟現在一樣看全部）
   · 新客的定義不動：封測來過的人，上線後再來不算新客（他本來就不是新客人）

   ⇒ 上線那天把 orgs.live_from 設成當天，兩件事一起切換，不用另外記得改
   ============================================================ */

-- ═══ 會員等級 ═══════════════════════════════════════════════
create or replace function public._tier_spend(p_member uuid, p_org uuid default null)
returns bigint language sql stable security definer set search_path = public as $$
  select coalesce(sum(o.payable), 0)::bigint
    from orders o
    join members m on m.id = o.member_id
    join orgs g on g.id = m.org_id
   where o.member_id = p_member
     and (p_org is null or o.org_id = p_org)
     and o.status = 'paid'
     and o.paid_at >= coalesce(g.live_from, 'infinity'::timestamptz)   -- 上線日之前（含還沒設上線日）一律不算
$$;
revoke execute on function public._tier_spend(uuid, uuid) from public, anon, authenticated;
comment on function public._tier_spend(uuid, uuid) is
  '會員等級的累積消費（唯一一份）：已付款訂單 payable，只算上線日（orgs.live_from）之後；上線日沒設 ⇒ 0';

create or replace function public.recalc_member_tier_tx(p_member_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_org uuid; v_cur text; v_spent bigint;
  v_new text; v_cur_sort int; v_new_sort int;
begin
  select org_id, tier into v_org, v_cur
    from members where id = p_member_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  -- 🆕 2026-11-03：改叫共用的 _tier_spend（只算上線日之後）
  v_spent := public._tier_spend(p_member_id);

  /* 達標的**最高**一階。`threshold_amount is not null` 把邀請制排除掉。 */
  select code, sort into v_new, v_new_sort
    from member_tiers
   where is_active and threshold_amount is not null and threshold_amount <= v_spent
   order by sort desc limit 1;

  if v_new is null then
    return jsonb_build_object('ok', true, 'spent', v_spent, 'tier', v_cur, 'changed', false);
  end if;

  select sort into v_cur_sort from member_tiers where code = v_cur;

  /* 🔴 **只升不降**。這一行同時擋掉三件事：
     ① 訂單被作廢讓累積變少 → 不降
     ② 日後把門檻調高 → 已達成的人不會被拉下來
     ③ 被手動設成主廚特調的人 → 它的 sort 最大，自動升等碰不到他 */
  if v_cur is not null and v_cur_sort >= v_new_sort then
    return jsonb_build_object('ok', true, 'spent', v_spent, 'tier', v_cur, 'changed', false);
  end if;

  update members set tier = v_new, updated_at = now() where id = p_member_id;
  return jsonb_build_object('ok', true, 'spent', v_spent,
                            'tier', v_new, 'from', v_cur, 'changed', true);
end $$;

create or replace function public.member_tier_progress_tx(p_member_id uuid, p_org_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_org      uuid;
  v_tier     text;
  v_pct      int;
  v_override text;
  v_spend    bigint;
  v_earned   text;
  v_curthr   bigint;
  v_base     bigint;
  v_next     record;
begin
  select coalesce(p_org_id, m.org_id), m.tier_override, coalesce(m.tier_override, m.tier)
    into v_org, v_override, v_tier
    from members m
   where m.id = p_member_id and m.deleted_at is null
     and (p_org_id is null or m.org_id = p_org_id);

  if v_org is null then return null; end if;   -- 呼叫端自己決定怎麼處理

  select coalesce(t.discount_pct, 0), t.threshold_amount
    into v_pct, v_curthr
    from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);

  -- 🆕 2026-11-03：改叫共用的 _tier_spend（只算上線日之後），跟真的升等同一份
  v_spend := public._tier_spend(p_member_id, v_org);

  /* 「憑消費賺到的」等級 —— 與 `tier_override` 分開，
     這樣畫面可以說「你被指定為主廚特調」而不是假裝他消費達標。 */
  select t.code into v_earned
    from member_tiers t
   where t.is_active and t.threshold_amount is not null
     and t.threshold_amount <= v_spend
   order by t.threshold_amount desc
   limit 1;

  /* 🔴 **這一行是 2026-08-25 修過的坑，抽出來時最容易弄丟**：
     基準取「本級門檻」與「累積額」的大者，否則等級被人工設高的人
     會看到一個比自己低的「下一級」。
     ⚠ `v_curthr is null` ＝ 邀請制（主廚特調）⇒ 基準是最大值 ⇒ 沒有下一級。 */
  v_base := greatest(coalesce(v_curthr, 9223372036854775807::bigint), v_spend);

  select t.code, t.label, t.threshold_amount into v_next
    from member_tiers t
   where t.is_active and t.threshold_amount is not null
     and t.threshold_amount > v_base
   order by t.threshold_amount asc
   limit 1;

  return jsonb_build_object(
    'tier',                v_tier,
    'tier_discount_pct',   v_pct,
    'tier_threshold',      v_curthr,
    'tier_by_override',    (v_override is not null),
    'tier_earned',         v_earned,
    'lifetime_spend',      v_spend,
    'counting_from',       (select live_from from orgs where id = v_org),   -- 🆕 null ＝ 還沒開始累積（上線日沒設）
    'next_tier',           v_next.code,
    'next_tier_label',     v_next.label,
    'next_tier_threshold', v_next.threshold_amount,
    'next_tier_gap',       case when v_next.threshold_amount is null then null
                                else v_next.threshold_amount - v_spend end
  );
end $$;

-- ═══ 報表：終身價值與新客分群從上線日開始 ═══════════════════════
-- 四處各只出現一次（2026-11-03 用 regexp_count 查過）；對不上就整份不執行
do $$
declare d text; n int;
begin
  d := pg_get_functiondef('public._ops_report_core(uuid, date, date, uuid)'::regprocedure);

  if regexp_count(d, 'v_used numeric; v_cap numeric;') <> 1
     or regexp_count(d, 'from _va where store_id in \(select id from _rs\)\),') <> 1
     or regexp_count(d, 'from _va\s+where store_id in \(select id from _rs\) group by 1\)') <> 1
     or regexp_count(d, 'and not m\.is_test\s+group by 1\)') <> 1 then
    raise exception '報表函式的原文跟預期不同，沒有改（請先查線上版本）';
  end if;

  d := regexp_replace(d, 'v_used numeric; v_cap numeric;',
         'v_used numeric; v_cap numeric;' || E'\n'
         || '  v_live timestamptz := (select g.live_from from orgs g where g.id = p_org);   -- 上線日（null ＝ 還沒上線，看全部）' || E'\n'
         || '  v_live_d date := public._biz_date((select g.live_from from orgs g where g.id = p_org));');
  -- 新客分群：只看上線日之後的來店
  d := regexp_replace(d, 'from _va where store_id in \(select id from _rs\)\),',
         'from _va where store_id in (select id from _rs) and (v_live_d is null or d >= v_live_d)),');
  -- 終身價值：來店與付款都只看上線日之後
  d := regexp_replace(d, 'from _va(\s+)where store_id in \(select id from _rs\) group by 1\)',
         'from _va\1where store_id in (select id from _rs) and (v_live_d is null or d >= v_live_d) group by 1)');
  d := regexp_replace(d, 'and not m\.is_test(\s+)group by 1\)',
         'and not m.is_test and (v_live is null or o.paid_at >= v_live)\1group by 1)');

  execute d;
end $$;

-- ── 驗證（不 raise，硬規則 1.8）────────────────────────────────
do $$
declare v text := ''; n int; d text; v_m uuid; v_raw bigint; v_s bigint; v_live timestamptz;
begin
  -- ① 兩支升等函式都改叫 _tier_spend，而且不再自己加總
  select count(*) into n from pg_proc p where p.pronamespace = 'public'::regnamespace
     and p.proname in ('recalc_member_tier_tx', 'member_tier_progress_tx')
     and pg_get_functiondef(p.oid) ~ '_tier_spend\('
     and pg_get_functiondef(p.oid) !~ 'sum\([a-z]*\.?payable\)';
  v := v || case when n = 2 then '✅' else '🔴' end || ' ① 兩支升等函式都用 _tier_spend、不再自己加總（' || n || '/2）' || E'\n';

  -- ② _tier_spend 前端叫不到
  v := v || case when not has_function_privilege('authenticated', 'public._tier_spend(uuid, uuid)', 'EXECUTE')
                  and not has_function_privilege('anon', 'public._tier_spend(uuid, uuid)', 'EXECUTE') then '✅' else '🔴' end
          || ' ② _tier_spend 前端叫不到' || E'\n';

  -- ③ 上線日還沒設 ⇒ 累積一律 0（拿目前累積最多的那位當樣本）
  select live_from into v_live from orgs where id = (select org_id from members where not is_test limit 1);
  select o.member_id, sum(o.payable) into v_m, v_raw from orders o join members m on m.id = o.member_id
   where o.status = 'paid' and not m.is_test group by 1 order by 2 desc limit 1;
  v_s := public._tier_spend(v_m);
  v := v || case when v_live is null and v_s = 0 then '✅'
                 when v_live is not null then '⚪' else '🔴' end
          || ' ③ 上線日 ' || coalesce(v_live::text, '還沒設') || '：累積最多的那位原本 $' || coalesce(v_raw, 0) || '，現在算 $' || coalesce(v_s, 0) || E'\n';

  -- ④ 正對照：在子交易裡暫時把上線日設成很早，累積要回到原本的金額（之後回滾，不留下任何改動）
  begin
    update orgs set live_from = '2000-01-01' where id = (select org_id from members where id = v_m);
    v_s := public._tier_spend(v_m);
    raise exception 'migi_probe:%', v_s;
  exception when others then
    if sqlerrm like 'migi_probe:%' then
      v_s := split_part(sqlerrm, ':', 2)::bigint;
      v := v || case when v_s = v_raw then '✅' else '🔴' end
              || ' ④ 正對照：上線日設成 2000-01-01 時算 $' || v_s || '（應該 ＝ $' || v_raw || '，已回滾）' || E'\n';
    else
      v := v || '🔴 ④ 正對照失敗：' || sqlerrm || E'\n';
    end if;
  end;
  select live_from into v_live from orgs where id = (select org_id from members where id = v_m);
  v := v || case when v_live is null then '✅' else '🔴' end || ' ⑤ 正對照之後上線日仍然是 ' || coalesce(v_live::text, '沒設') || E'\n';

  -- ⑥ 會員等級沒有人被動到（目前全是第一級）
  select count(*) into n from members where not is_test and deleted_at is null and coalesce(tier_override, tier) <> 'bubble_tea';
  v := v || case when n = 0 then '✅' else '⚠' end || ' ⑥ 不是珍珠奶茶的非測試會員 ' || n || ' 位（期望 0）' || E'\n';

  -- ⑦ 報表函式改到了：三處都帶上線日的條件
  d := pg_get_functiondef('public._ops_report_core(uuid, date, date, uuid)'::regprocedure);
  n := regexp_count(d, 'v_live_d is null or d >= v_live_d') + regexp_count(d, 'v_live is null or o\.paid_at >= v_live');
  v := v || case when n = 3 then '✅' else '🔴' end || ' ⑦ 報表函式帶上線日條件的地方 ' || n || '/3（分群 1 ＋ 終身價值 2）';

  perform set_config('migi.live', v, true);
end $$;

select coalesce(nullif(current_setting('migi.live', true), ''), '🔴 沒有訊息') as "驗證";
